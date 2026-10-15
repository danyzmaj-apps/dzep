import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dzep_core/agent.dart';
import 'package:dzep_core/ansi.dart';
import 'package:dzep_core/apple_terminal.dart';
import 'package:dzep_core/backend.dart';
import 'package:dzep_core/chat.dart';
import 'package:dzep_core/chat_images.dart';
import 'package:dzep_core/ghostty.dart';
import 'package:dzep_core/idea.dart';
import 'package:dzep_core/iterm.dart';
import 'package:dzep_core/kitty.dart';
import 'package:dzep_core/live.dart';
import 'package:dzep_core/remind.dart';
import 'package:dzep_core/terminal.dart';
import 'package:dzep_core/tmux.dart';
import 'package:dzep_core/wezterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Inputs a parser meets in the wild and some it never should: random bytes
/// read as text, very long lines, unicode (combining marks, emoji, RTL,
/// control characters), tabs and separators the formats use, and JSON of
/// any shape. Seeded, so a failure names its input and replays.
class Gen {
  Gen(int seed) : r = Random(seed);
  final Random r;

  static const _pieces = [
    '\t',
    '\n',
    '\r\n',
    ' ',
    '"',
    "'",
    r'\',
    '{',
    '}',
    '[',
    ']',
    ':',
    ',',
    '/',
    '=',
    '&',
    '?',
    '#',
    '%',
    '@',
    '\x1b[',
    '\x1b]',
    'm',
    ';',
    '38;5;',
    '48;2;',
    '0',
    '1',
    '255',
    '-1',
    '99999999999999999999',
    'NaN',
    'kitty-1/2',
    'tmux:',
    'dzep://setup?',
    'url=',
    'key=',
    'code=',
    'https://',
    'http://10.',
    '!',
    'tmr',
    '3pm',
    '9.30',
    'é',
    '\u0301',
    '😀',
    '👩‍💻',
    '\u202e',
    '\u0000',
    '\uFFFD',
    '\uD83D',
    'ж',
    '中文',
    '❯',
    '│',
    '─',
    '›',
    '●',
  ];

  String text({int max = 200}) {
    final b = StringBuffer();
    final n = r.nextInt(max);
    for (var i = 0; i < n; i++) {
      b.write(switch (r.nextInt(4)) {
        0 => String.fromCharCode(r.nextInt(0x3000)),
        1 => _pieces[r.nextInt(_pieces.length)],
        _ => String.fromCharCode(32 + r.nextInt(95)),
      });
    }
    return b.toString();
  }

  /// Random bytes, decoded the way a process's output is (malformed allowed).
  String bytes({int max = 400}) =>
      utf8.decode(List.generate(r.nextInt(max), (_) => r.nextInt(256)), allowMalformed: true);

  String long() => text(max: 20) * (1000 + r.nextInt(4000));

  Object? json({int depth = 0}) => switch (depth > 3 ? r.nextInt(5) : r.nextInt(7)) {
    0 => null,
    1 => r.nextBool(),
    2 => r.nextInt(1 << 31) - (1 << 30),
    3 => r.nextDouble() * 1e6,
    4 => text(max: 30),
    5 => [for (var i = r.nextInt(4); i > 0; i--) json(depth: depth + 1)],
    _ => {for (var i = r.nextInt(5); i > 0; i--) key(): json(depth: depth + 1)},
  };

  static const _keys = [
    'id',
    'title',
    'cwd',
    'kind',
    'state',
    'is_focused',
    'tabs',
    'windows',
    'pid',
    'foreground_processes',
    'cmdline',
    'pane_id',
    'tab_id',
    'window_id',
    'user_vars',
    'dzep',
    'TERM_PROGRAM',
    'KITTY_WINDOW_ID',
    'KITTY_PID',
    'TMUX',
    'TMUX_PANE',
    'WEZTERM_PANE',
    'ITERM_SESSION_ID',
    'tty',
    'name',
    'description',
    'configured',
    'model',
    'base_url',
  ];
  String key() => r.nextInt(4) == 0 ? text(max: 8) : _keys[r.nextInt(_keys.length)];

  String any() => switch (r.nextInt(4)) {
    0 => bytes(),
    1 => long(),
    2 => jsonEncode(json()),
    _ => text(),
  };
}

/// Runs [body] on [rounds] generated inputs. A bug shows as an [Error]
/// (TypeError, RangeError, StateError…): a parser may refuse its input with
/// an [Exception], never crash on it, unless [contained]: then its caller
/// catches everything, and only a hang is a bug. Each round must be quick.
void property(String name, void Function(Gen g) body, {int rounds = 300, bool contained = false}) {
  test(name, () {
    for (var seed = 0; seed < rounds; seed++) {
      final watch = Stopwatch()..start();
      try {
        body(Gen(seed));
      } on Exception {
        // Refused: fine.
      } catch (e, st) {
        // An Error, or anything else that isn't an Exception: a crash.
        if (!contained) fail('seed $seed: $e\n$st');
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)), reason: 'seed $seed hangs');
    }
  });
}

void main() {
  final now = DateTime.utc(2026, 10, 15, 9);
  final colors = TermColors(foreground: Colors.white, background: Colors.black, palette: List.filled(16, Colors.grey));

  group('setup links and pairing codes', () {
    property('Backend.fromLink, pairingCode and parse take anything', (g) {
      for (final raw in [
        g.text(),
        g.bytes(),
        'dzep://setup?${g.text()}',
        'dzep://setup?url=${g.text()}&key=${g.text()}&code=${g.text()}',
      ]) {
        final uri = Uri.tryParse(raw);
        if (uri != null) {
          Backend.fromLink(uri);
          Backend.pairingCode(uri);
        }
        Backend.parse(raw, g.text());
      }
    });
  });

  group('typed text', () {
    property('titles, notes and reminders', (g) {
      final s = g.any();
      parseTitle(s);
      noteTitle(s);
      parseReminder(s, now);
      parseWhen(s, now);
    });
  });

  group('terminal output', () {
    property('screens, ANSI and menus', (g) {
      final s = g.any();
      screenLines(s);
      ansiSpans(s, colors);
      parseMenu(s);
      for (final agent in Agent.values) {
        parsePlanReview(s, agent: agent);
      }
    });

    property('terminal listings: tmux, iTerm2, Terminal, Ghostty, ps, lsof', (g) {
      final s = g.any();
      parseTmuxPanes('default', s);
      parseTmuxClients('default', s);
      parseITermList(s);
      parseTerminalList(s);
      parseGhosttyList(s);
      parsePs(s);
      parseLsofCwd(s);
    });

    // kitty's and WezTerm's own JSON: a shape they never send may throw;
    // Terminals.windows catches whatever a host throws (terminals.dart).
    property('kitty and WezTerm listings of any shape', contained: true, (g) {
      final json = jsonEncode(g.json());
      parseKittyLs('kitty-1', json);
      parseWezTermList('1', json);
      dzepTabSpot(json);
      lastInOsWindow(json, g.r.nextInt(10));
    });

    property("an agent's term and its commands", (g) {
      final term = g.json();
      windowOfTerm(
        term is Map<String, dynamic>
            ? term
            : {
                for (final k in ['TERM_PROGRAM', 'TMUX', 'tty']) k: g.json(),
              },
      );
      liveCommands(g.json());
      AiStatus.fromJson(g.json());
      Kind.parse(g.json());
    });
  });

  group('images', () {
    property('sniffing random bytes', (g) {
      sniffImageType(Uint8List.fromList(List.generate(g.r.nextInt(64), (_) => g.r.nextInt(256))));
    });
  });
}
