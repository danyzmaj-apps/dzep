import 'package:dzep_core/agent.dart';
import 'package:dzep_core/terminal.dart';
import 'package:flutter_test/flutter_test.dart';

// Outputs and environments below were captured on a Mac (macOS 26, tmux 3.6,
// WezTerm 20240203, iTerm2 3.6, Ghostty 1.3.1, kitty 0.4x), names shortened.

/// `ps -Ao pid=,ppid=,pgid=,tpgid=,tty=,stat=,args=`: a Terminal tab (login,
/// then zsh in front), a Ghostty window attached to tmux (login, tmux client
/// in front), omp running in a tab, and a daemon without a tty.
const _ps = '''
98233 94784 98233 98234 ttys009  Ss   login -pf me
98234 98233 98234 98234 ttys009  S+   -zsh
97914 97159 97914 97914 ttys010  Ss+  /usr/bin/login -flp me /bin/bash --noprofile --norc -c exec -l '/opt/homebrew/bin/tmux' 'attach-session' '-t' '=dzep-mv82o7z3'
97915 97914 97914 97914 ttys010  S+   -/opt/homebrew/bin/tmux attach-session -t =dzep-mv82o7z3
 5150  5149  5150  5249 ttys008  Ss   -zsh
 5249  5150  5249  5249 ttys008  Rl+  omp --no-extensions -e /Users/me/live.ts
 7885 95874  7885     -1 ?        Rsl  /opt/homebrew/Cellar/omp/18.4.2/bin/omp __omp_worker_daemon_broker
''';

void main() {
  group('processes', () {
    test('parsePs reads every line, a missing tty as empty', () {
      final procs = parsePs(_ps);
      expect(procs.map((p) => p.pid), [98233, 98234, 97914, 97915, 5150, 5249, 7885]);
      final daemon = procs.last;
      expect((daemon.ppid, daemon.pgid, daemon.tpgid, daemon.tty, daemon.stat), (95874, 7885, -1, '', 'Rsl'));
      expect(procs[5].args, 'omp --no-extensions -e /Users/me/live.ts');
    });

    test('the foreground program of a tty is the leader of its foreground group', () {
      final procs = Procs(parsePs(_ps));
      expect(procs.foreground('ttys009')?.program, 'zsh');
      expect(procs.foreground('/dev/ttys008')?.program, 'omp');
      expect(procs.foreground('ttys008')?.pid, 5249);
      expect(procs.foreground('ttys099'), isNull);
      expect(procs.foreground(''), isNull);
    });

    test('programOf names the program, a login shell without its dash, a script by its name', () {
      expect(programOf('-zsh'), 'zsh');
      expect(programOf('/opt/homebrew/Cellar/omp/18.4.2/bin/omp __omp_worker_daemon_broker'), 'omp');
      expect(programOf('-/opt/homebrew/bin/tmux attach-session -t =x'), 'tmux');
      expect(programOf('node --no-warnings /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js'), 'cli');
      expect(programOf('bun /Users/me/bin/omp.ts --continue'), 'omp');
      expect(programOf('python3 -u server.py'), 'server');
      expect(programOf('claude'), 'claude');
      expect(programOf('   '), '');
    });

    test('parseLsofCwd maps each pid to its folder', () {
      const out = 'p98234\nfcwd\nn/private/tmp/dzt/cap-terminal\np1129\nfcwd\nn/Users/me/Dev/x y\n';
      expect(parseLsofCwd(out), {98234: '/private/tmp/dzt/cap-terminal', 1129: '/Users/me/Dev/x y'});
      expect(parseLsofCwd(''), isEmpty);
    });
  });

  group('keys', () {
    test('keyBytes sends what a terminal sends for each key, Shift+Enter as Alt+Enter', () {
      expect(keyBytes('enter'), '\r');
      expect(keyBytes('esc'), '\x1b');
      expect(keyBytes('tab'), '\t');
      expect(keyBytes('shift+tab'), '\x1b[Z');
      expect(keyBytes('up'), '\x1b[A');
      expect(keyBytes('left'), '\x1b[D');
      expect(keyBytes('backspace'), '\x7f');
      expect(keyBytes('shift+enter'), '\x1b\r');
      expect(keyBytes('ctrl+c'), '\x03');
      expect(keyBytes('ctrl+a'), '\x01');
      expect(keyBytes('3'), '3');
      expect(() => keyBytes('ctrl+shift+x'), throwsA(isA<TerminalException>()));
    });

    test('keyRuns keeps Esc apart, so what follows is not read as Alt+key', () {
      expect(keyRuns(['down', 'down', 'enter']), ['\x1b[B\x1b[B\r']);
      expect(keyRuns(['up', 'esc', 'x']), ['\x1b[A', '\x1b', 'x']);
      expect(keyRuns(['esc']), ['\x1b']);
      expect(keyRuns([]), isEmpty);
    });
  });

  group('windowOfTerm', () {
    test('kitty: the socket it listens on, else its pid', () {
      expect(
        windowOfTerm({'KITTY_WINDOW_ID': '7', 'KITTY_PID': '88858', 'KITTY_LISTEN_ON': 'unix:/tmp/dzt/ks/kitty'}),
        'kitty/7',
      );
      expect(
        windowOfTerm({'KITTY_WINDOW_ID': '116', 'KITTY_PID': '23224', 'KITTY_LISTEN_ON': 'unix:/tmp/kitty-23224'}),
        'kitty-23224/116',
      );
      expect(windowOfTerm({'KITTY_WINDOW_ID': '3', 'KITTY_PID': '501'}), 'kitty-501/3');
      // A socket that isn't kitty's own name can't be found again.
      expect(windowOfTerm({'KITTY_WINDOW_ID': '3', 'KITTY_LISTEN_ON': 'unix:/tmp/other'}), isNull);
    });

    test('tmux wins over the terminal showing it, even with kitty variables leaked in', () {
      expect(
        windowOfTerm({
          'TERM_PROGRAM': 'tmux',
          'KITTY_WINDOW_ID': '116',
          'KITTY_PID': '23224',
          'KITTY_LISTEN_ON': 'unix:/tmp/kitty-23224',
          'TMUX': '/private/tmp/tmux-501/default,4226,0',
          'TMUX_PANE': '%0',
        }),
        'tmux:default/0',
      );
      expect(windowOfTerm({'TMUX': '/private/tmp/tmux-501/work,1,0', 'TMUX_PANE': '%12'}), 'tmux:work/12');
    });

    test('WezTerm and Ghostty started from kitty: their own TERM_PROGRAM wins over the leaked KITTY_*', () {
      const leaked = {'KITTY_WINDOW_ID': '116', 'KITTY_PID': '23224', 'KITTY_LISTEN_ON': 'unix:/tmp/kitty-23224'};
      expect(
        windowOfTerm({
          ...leaked,
          'TERM_PROGRAM': 'WezTerm',
          'WEZTERM_PANE': '2',
          'WEZTERM_UNIX_SOCKET': '/Users/me/.local/share/wezterm/gui-sock-40899',
        }),
        'wezterm:40899/2',
      );
      // Ghostty tells nothing to match: Terminals.locate finds it by folder.
      expect(windowOfTerm({...leaked, 'TERM_PROGRAM': 'ghostty', 'tty': '/dev/ttys007'}), isNull);
    });

    test('iTerm2 by its session id, Terminal by its tty', () {
      expect(
        windowOfTerm({'TERM_PROGRAM': 'iTerm.app', 'ITERM_SESSION_ID': 'w0t1p0:6A4030A3-8364-4898-9CEA-F189424E874A'}),
        'iterm:6A4030A3-8364-4898-9CEA-F189424E874A',
      );
      expect(
        windowOfTerm({
          'TERM_PROGRAM': 'Apple_Terminal',
          'TERM_SESSION_ID': '4B0E2E4C-55B8-4F2F-9C55-6B8D9E1D2F10',
          'tty': '/dev/ttys009',
        }),
        'terminal:ttys009',
      );
      // Terminal without a tty can't be told.
      expect(windowOfTerm({'TERM_PROGRAM': 'Apple_Terminal'}), isNull);
    });

    test('nothing known: null', () {
      expect(windowOfTerm(null), isNull);
      expect(windowOfTerm({}), isNull);
      expect(windowOfTerm({'TERM_PROGRAM': 'vscode', 'tty': '/dev/ttys003'}), isNull);
    });
  });

  group('TermWindow', () {
    test("an older Mac's window (no app, no caps) is kitty's, able to do everything", () {
      final w = TermWindow.fromJson({'key': 'kitty-1/2', 'title': 't', 'program': 'claude'});
      expect(w.app, 'kitty');
      expect(w.caps, allCaps);
      expect(w.agent, Agent.claude);
    });

    test('caps and via survive the trip to the phone; unknown caps are dropped', () {
      const w = TermWindow(
        key: 'tmux:default/0',
        title: 'x',
        tab: 's:w',
        cwd: '/x',
        program: 'zsh',
        app: 'tmux',
        via: 'Ghostty',
        caps: {TermCap.type, TermCap.keys},
      );
      final back = TermWindow.fromJson({
        ...w.toJson(),
        'caps': [...(w.toJson()['caps'] as List), 'teleport'],
      });
      expect((back.app, back.via), ('tmux', 'Ghostty'));
      expect(back.caps, {TermCap.type, TermCap.keys});
    });
  });
}
