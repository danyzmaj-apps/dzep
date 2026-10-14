import 'package:dzep_core/apple_terminal.dart';
import 'package:dzep_core/ghostty.dart';
import 'package:dzep_core/iterm.dart';
import 'package:dzep_core/kitty.dart';
import 'package:dzep_core/terminal.dart';
import 'package:dzep_core/terminals.dart';
import 'package:dzep_core/tmux.dart';
import 'package:dzep_core/wezterm.dart';
import 'package:flutter_test/flutter_test.dart';

// Real outputs captured from each app (names shortened), with the `ps`
// lines of the same windows.

const _psTerminal = '''
98233 94784 98233 98234 ttys009  Ss   login -pf me
98234 98233 98234 98234 ttys009  S+   -zsh
''';

const _psITerm = '''
98802 98785 98802 98803 ttys008  Ss   /usr/bin/login -fpl me /Applications/iTerm.app/Contents/MacOS/ShellLauncher --launch_shell
98803 98802 98803 98803 ttys008  S+   -zsh
''';

const _psWezTerm = ' 1129  1128  1129 5249 ttys008  Ss+  -zsh\n 5249  1129  5249 5249 ttys008  S+   claude\n';

const _wezList = '''
[
  {
    "window_id": 0, "tab_id": 0, "pane_id": 0, "workspace": "default",
    "size": {"rows": 24, "cols": 80, "pixel_width": 1120, "pixel_height": 768, "dpi": 144},
    "title": "cap-wezterm", "cwd": "file://mac.local/tmp/dzt/cap-wezterm",
    "cursor_x": 15, "cursor_y": 0, "cursor_shape": "Default", "cursor_visibility": "Visible",
    "left_col": 0, "top_row": 0, "tab_title": "", "window_title": "cap-wezterm",
    "is_active": true, "is_zoomed": false, "tty_name": "/dev/ttys008"
  }
]''';

/// Hosts that touch nothing on this Mac (paths that don't exist).
Terminals _terms() => Terminals(
  kitty: Kitty(socketDir: '/nonexistent-dzep', home: '/nonexistent-dzep', restoreFront: false),
  tmux: Tmux(executable: '/nonexistent-dzep/tmux', socketDirs: const []),
  wezterm: WezTerm(executable: '/nonexistent-dzep/wezterm', socketDir: '/nonexistent-dzep'),
  iterm: ITerm(appPath: '/nonexistent-dzep/iTerm.app'),
  terminal: AppleTerminal(appPath: '/nonexistent-dzep/Terminal.app'),
  ghostty: Ghostty(appPath: '/nonexistent-dzep/Ghostty.app'),
);

TermWindow _w(String key, {String tty = '', String app = 'x'}) =>
    TermWindow(key: key, title: '', tab: '', cwd: '', program: '', app: app, tty: tty);

void main() {
  group('tmux', () {
    test('list-panes: a pane per line, its program from the tty, the window name for a host-name title', () {
      const out =
          '%0\t/dev/ttys008\tzsh\t/private/tmp/dzt/cap-tmux\tcap-tmux\tzsh\tdzep-mv82o7z3\t1\t1\t1\n'
          '%3\t/dev/ttys012\tnode\t/Users/me/Dev/x\t\teditor\twork\t1\t0\t0\n';
      final procs = Procs(parsePs(' 97892 97891 97892 97892 ttys008  Ss+  -zsh\n'));
      final panes = parseTmuxPanes('default', out, procs);
      expect(panes.map((w) => w.key), ['tmux:default/0', 'tmux:default/3']);
      final first = panes.first;
      expect(
        (first.title, first.tab, first.cwd, first.program, first.tty, first.focused, first.app),
        ('cap-tmux', 'dzep-mv82o7z3:zsh', '/private/tmp/dzt/cap-tmux', 'zsh', 'ttys008', true, 'tmux'),
      );
      expect(first.caps, allCaps);
      // No ps entry: tmux's own idea of the command; an inactive window isn't focused.
      expect((panes[1].title, panes[1].program, panes[1].focused), ('editor', 'node', false));
    });

    test('list-clients: client tty → the pane it shows', () {
      expect(parseTmuxClients('default', '/dev/ttys009\t%0\n/dev/ttys011\t%14\n\n'), {
        'ttys009': 'tmux:default/0',
        'ttys011': 'tmux:default/14',
      });
    });

    test("send-keys runs: tmux's key names, characters literally, Shift+Enter as M-Enter", () {
      final runs = tmuxKeyRuns(['down', 'enter', '1', ';', 'esc', 'shift+enter', 'ctrl+c', 'shift+tab']);
      expect(runs.map((r) => r.literal), [false, true, false]);
      expect(runs.map((r) => r.keys), [
        ['Down', 'Enter'],
        ['1', ';'],
        ['Escape', 'M-Enter', 'C-c', 'BTab'],
      ]);
      expect(() => tmuxKeyRuns(['hyper+x']), throwsA(isA<TerminalException>()));
    });
  });

  test('WezTerm list: pane key with the GUI pid, folder from the file URL, program from the tty', () {
    final w = parseWezTermList('1128', _wezList, Procs(parsePs(_psWezTerm))).single;
    expect(
      (w.key, w.title, w.cwd, w.tty, w.program, w.focused, w.app),
      ('wezterm:1128/0', 'cap-wezterm', '/tmp/dzt/cap-wezterm', 'ttys008', 'claude', true, 'wezterm'),
    );
  });

  test('iTerm2 list: a session per line; focused only while iTerm2 is in front', () {
    const out = '6A4030A3-8364-4898-9CEA-F189424E874A\t/dev/ttys008\tcap-iterm (-zsh)\t1\t1\ttrue\nfront\tfalse\n';
    final w = parseITermList(out, Procs(parsePs(_psITerm))).single;
    expect(
      (w.key, w.title, w.tab, w.tty, w.program, w.focused),
      ('iterm:6A4030A3-8364-4898-9CEA-F189424E874A', 'cap-iterm (-zsh)', 'Tab 1', 'ttys008', 'zsh', false),
    );
    expect(parseITermList(out.replaceFirst('front\tfalse', 'front\ttrue')).single.focused, isTrue);
  });

  test('Terminal list: a tab per line keyed by its tty, its custom title first', () {
    const out =
        '/dev/ttys009\tcap-terminal — cap-terminal — -zsh — 120×30\t1\t1\ttrue\tcap-terminal\r'
        '/dev/ttys010\tme — ~ — -zsh — 120×30\t1\t2\tfalse\t\r'
        'front\ttrue';
    final tabs = parseTerminalList(out, Procs(parsePs(_psTerminal)));
    expect(tabs.map((w) => (w.key, w.title, w.tab, w.program, w.focused)), [
      ('terminal:ttys009', 'cap-terminal', 'Tab 1', 'zsh', true),
      ('terminal:ttys010', 'me', 'Tab 2', '', false),
    ]);
  });

  test("Ghostty list: id, title and folder; no tty, and its windows can't be read", () {
    const out =
        'CB2035E7-67BF-48C7-8D0A-83F3FA5B8074\tcap-ghostty\t/tmp/dzt/cap-ghostty\tcap-ghostty\ttrue\nfront\tfalse\n';
    final w = parseGhosttyList(out).single;
    expect(
      (w.key, w.title, w.cwd, w.tty, w.focused),
      ('ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074', 'cap-ghostty', '/tmp/dzt/cap-ghostty', '', false),
    );
    expect(w.can(TermCap.read), isFalse);
    expect(w.can(TermCap.keys), isTrue);
  });

  test("ghosttyText escapes what a Zig string literal can't hold", () {
    expect(ghosttyText(r'echo "a\b"'), r'echo \"a\\b\"');
    expect(ghosttyText('\x1b[A\r\x7f'), r'\x1b[A\x0d\x7f');
    expect(ghosttyText('čšž ✓'), 'čšž ✓');
  });

  group('Terminals.merge', () {
    final terms = _terms();

    test("a terminal window attached to tmux gives way to the tmux pane, which names the app it's in", () {
      final merged = Terminals.merge(
        terms.hosts,
        [
          [_w('kitty-1/2', tty: 'ttys003')],
          [_w('tmux:default/0', tty: 'ttys008'), _w('tmux:default/1', tty: 'ttys011')],
          [],
          [_w('iterm:A', tty: 'ttys009')],
          [_w('terminal:ttys010', tty: 'ttys010')],
          [],
        ],
        {'ttys009': 'tmux:default/0'},
        const {},
      );
      expect(merged.map((w) => (w.key, w.via)), [
        ('kitty-1/2', ''),
        ('tmux:default/0', 'iTerm2'),
        ('tmux:default/1', ''),
        ('terminal:ttys010', ''),
      ]);
    });

    test('a Ghostty window (no tty) Džep opened to show a pane gives way through the shows map', () {
      final merged = Terminals.merge(
        terms.hosts,
        [
          [],
          [_w('tmux:default/4', tty: 'ttys012')],
          [],
          [],
          [],
          [_w('ghostty:G1'), _w('ghostty:G2')],
        ],
        const {},
        {'ghostty:G1': 'tmux:default/4'},
      );
      expect(merged.map((w) => (w.key, w.via)), [('tmux:default/4', 'Ghostty'), ('ghostty:G2', '')]);
    });
  });

  group('pickApp', () {
    final terms = _terms();
    TermStatus s(String id, TermState state) => TermStatus(id, id, state);
    final statuses = {
      'kitty': s('kitty', TermState.setup),
      'iterm': s('iterm', TermState.limited),
      'wezterm': s('wezterm', TermState.ready),
      'ghostty': s('ghostty', TermState.idle),
      'terminal': s('terminal', TermState.limited),
    };

    test('a chosen app that is installed wins, even when not running', () {
      expect(Terminals.pickApp(terms.apps, statuses, 'ghostty', ['WezTerm']).id, 'ghostty');
    });

    test('Auto: the usable app used most recently, skipping ones that need setup', () {
      expect(Terminals.pickApp(terms.apps, statuses, 'auto', ['Zen', 'kitty', 'Terminal', 'WezTerm']).id, 'terminal');
      // A missing choice falls back the same way.
      final noGhostty = {...statuses, 'ghostty': s('ghostty', TermState.missing)};
      expect(Terminals.pickApp(terms.apps, noGhostty, 'ghostty', ['iTerm2']).id, 'iterm');
    });

    test('Auto with none used lately: the first usable in preference order, else one that can be started', () {
      expect(Terminals.pickApp(terms.apps, statuses, 'auto', const []).id, 'iterm');
      final none = {
        'kitty': s('kitty', TermState.idle),
        'iterm': s('iterm', TermState.missing),
        'wezterm': s('wezterm', TermState.missing),
        'ghostty': s('ghostty', TermState.idle),
        'terminal': s('terminal', TermState.idle),
      };
      // kitty can't be started listening: Ghostty, the next idle app.
      expect(Terminals.pickApp(terms.apps, none, 'auto', const []).id, 'ghostty');
    });
  });

  test('new sessions run in tmux only where the app lacks screen or keys, and only with tmux', () {
    final terms = _terms();
    expect(terms.viaTmux(terms.terminal), isFalse); // no tmux here
    final withTmux = Terminals(
      kitty: terms.kitty,
      tmux: Tmux(executable: '/bin/sh', socketDirs: const []),
      wezterm: terms.wezterm,
      iterm: terms.iterm,
      terminal: terms.terminal,
      ghostty: terms.ghostty,
    );
    expect(withTmux.viaTmux(withTmux.terminal), isTrue);
    expect(withTmux.viaTmux(withTmux.ghostty), isTrue);
    expect(withTmux.viaTmux(withTmux.iterm), isFalse);
    expect(withTmux.describe(withTmux.ghostty), 'Ghostty (in tmux)');
    expect(withTmux.describe(withTmux.kitty), 'kitty');
  });
}
