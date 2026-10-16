import 'package:dzep_core/apple_terminal.dart';
import 'package:dzep_core/ghostty.dart';
import 'package:dzep_core/iterm.dart';
import 'package:dzep_core/kitty.dart';
import 'package:dzep_core/terminal.dart';
import 'package:dzep_core/terminals.dart';
import 'package:dzep_core/tmux.dart';
import 'package:dzep_core/wezterm.dart';
import 'package:dzep_macos/terminal_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// Terminals that touch nothing on this Mac; [tmux]: an executable that exists.
Terminals _terms({bool tmux = false}) => Terminals(
  kitty: Kitty(socketDir: '/nonexistent-dzep', home: '/nonexistent-dzep', restoreFront: false),
  tmux: Tmux(executable: tmux ? '/bin/sh' : '/nonexistent-dzep/tmux', socketDirs: const []),
  wezterm: WezTerm(executable: '/nonexistent-dzep/wezterm', socketDir: '/nonexistent-dzep'),
  iterm: ITerm(appPath: '/nonexistent-dzep/iTerm.app'),
  terminal: AppleTerminal(appPath: '/nonexistent-dzep/Terminal.app'),
  ghostty: Ghostty(appPath: '/nonexistent-dzep/Ghostty.app'),
);

void main() {
  group('answering an ask from the phone', () {
    test('works where the screen can be read and keys pressed', () {
      final terms = _terms();
      for (final key in ['kitty-1/2', 'tmux:default/0', 'wezterm:9/1', 'iterm:6A4030A3-8364-4898-9CEA-F189424E874A']) {
        expect(cantAnswer(terms, key), isNull, reason: key);
      }
    });

    test("Terminal can't press keys, Ghostty can't show its screen; tmux is the way out", () {
      expect(cantAnswer(_terms(tmux: true), 'terminal:ttys009'), startsWith("Terminal can't press keys"));
      expect(cantAnswer(_terms(tmux: true), 'terminal:ttys009'), contains('run in tmux there'));
      final ghostty = cantAnswer(_terms(), 'ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074')!;
      expect(ghostty, startsWith("Ghostty can't show its screen"));
      expect(ghostty, contains('brew install tmux'));
    });
  });

  test('the phone hears of installed terminals, and of tmux even when missing', () {
    const statuses = [
      TermStatus('kitty', 'kitty', TermState.ready),
      TermStatus('tmux', 'tmux', TermState.missing, note: 'Install tmux'),
      TermStatus('wezterm', 'WezTerm', TermState.missing),
      TermStatus('ghostty', 'Ghostty', TermState.limited),
    ];
    expect(phoneTerminals(statuses).map((s) => s.id), ['kitty', 'tmux', 'ghostty']);
  });

  test('an error only when nothing shows and no terminal is usable: the setup one', () {
    const setup = TermStatus('kitty', 'kitty', TermState.setup, note: "kitty isn't listening.");
    const idle = TermStatus('ghostty', 'Ghostty', TermState.idle);
    const limited = TermStatus('terminal', 'Terminal', TermState.limited);
    expect(terminalsError([idle, setup], nothingShown: true), "kitty isn't listening.");
    expect(terminalsError([idle, setup], nothingShown: false), isNull);
    expect(terminalsError([setup, limited], nothingShown: true), isNull);
    expect(terminalsError([idle], nothingShown: true), isNull);
  });

  test("a slash command for a session in no terminal Džep drives (IntelliJ's) is refused, not sent as chat", () {
    final terms = _terms();
    for (final key in [
      'kitty-1/2',
      'tmux:default/0',
      'terminal:ttys009',
      'ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074',
    ]) {
      expect(cantCommand(terms, key), isNull, reason: key);
    }
    expect(cantCommand(terms, null), startsWith("Slash commands are typed into the agent's terminal window"));
  });
}
