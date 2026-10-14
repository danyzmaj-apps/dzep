import 'dart:async';
import 'dart:io';

import 'package:dzep_core/terminal.dart';

/// tmux, whichever terminal shows it: every server of this user (the
/// default socket and any `-L` one in `$TMUX_TMPDIR/tmux-<uid>` or
/// `/private/tmp/tmux-<uid>`), through its command line. Window keys:
/// `tmux:<socket name>/<pane number>` (the pane `%n`).
class Tmux extends TerminalHost {
  Tmux({String? executable, List<String>? socketDirs, Map<String, String>? env})
    : _exe = executable ?? findExecutable('tmux', env: env),
      _dirs = socketDirs ?? _defaultDirs(env ?? Platform.environment);

  final String? _exe;
  final List<String> _dirs;

  /// Sockets learnt from agents (their `TMUX`), by name, for servers in a
  /// directory not scanned.
  final _known = <String, String>{};

  /// The clients attached on the last [windows]: their tty → the pane key
  /// they show, so a terminal window showing tmux can give way to its pane.
  Map<String, String> clients = const {};

  static List<String> _defaultDirs(Map<String, String> env) {
    final tmp = env['TMUX_TMPDIR'];
    final roots = {if (tmp != null && tmp.isNotEmpty) tmp, '/private/tmp'};
    final dirs = <String>[];
    for (final root in roots) {
      final d = Directory(root);
      if (!d.existsSync()) continue;
      try {
        for (final e in d.listSync(followLinks: false)) {
          if (e is Directory && e.uri.pathSegments.where((s) => s.isNotEmpty).last.startsWith('tmux-')) {
            dirs.add(e.path);
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    return dirs;
  }

  bool get installed => _exe != null && File(_exe).existsSync();

  @override
  String get id => 'tmux';

  @override
  String get label => 'tmux';

  @override
  String? get appName => null;

  @override
  Set<TermCap> get caps => allCaps;

  @override
  bool owns(String key) => key.startsWith('tmux:');

  /// A socket an agent named (its `TMUX`), for a server outside the
  /// directories scanned.
  void learn(String socketPath) {
    final name = socketPath.split('/').last;
    if (tmuxSocketName(name)) _known[name] = socketPath;
  }

  /// Socket name → path, for every live-looking socket we may open.
  Map<String, String> _sockets() {
    final out = <String, String>{..._known};
    for (final dir in _dirs) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      try {
        for (final e in d.listSync(followLinks: false)) {
          final name = e.uri.pathSegments.last;
          if (tmuxSocketName(name) &&
              FileSystemEntity.typeSync(e.path, followLinks: false) == FileSystemEntityType.unixDomainSock) {
            out[name] = e.path;
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    return out;
  }

  Future<String> _run(String socket, List<String> args) async {
    final exe = _exe;
    if (exe == null) throw const TerminalException('tmux is not installed. Install it with: brew install tmux');
    final ProcessResult r;
    try {
      r = await Process.run(exe, ['-S', socket, ...args]).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      throw const TerminalException('tmux did not answer.');
    }
    if (r.exitCode != 0) {
      final err = '${r.stderr}'.trim();
      if (err.contains("can't find pane") || err.contains('no server running')) {
        throw const TerminalException('That window is gone.');
      }
      throw TerminalException('tmux: $err');
    }
    return r.stdout as String;
  }

  (String socket, String pane) _parse(String key) {
    final m = RegExp(r'^tmux:([\w.-]+)/(\d+)$').firstMatch(key);
    final path = m == null ? null : _sockets()[m[1]];
    if (path == null) throw const TerminalException('That window is gone.');
    return (path, '%${m![2]}');
  }

  static const _format =
      '#{pane_id}\t#{pane_tty}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_title}\t'
      '#{window_name}\t#{session_name}\t#{pane_active}\t#{window_active}\t#{session_attached}';

  @override
  Future<TermStatus> status(Procs procs) async {
    if (!installed) {
      return TermStatus(
        id,
        label,
        TermState.missing,
        note: 'Install tmux for full control anywhere: brew install tmux',
      );
    }
    final n = (await windows(procs)).length;
    return TermStatus(
      id,
      label,
      n == 0 ? TermState.idle : TermState.ready,
      note: n == 0 ? 'No tmux server running' : '$n pane${n == 1 ? '' : 's'}',
    );
  }

  @override
  Future<List<TermWindow>> windows(Procs procs) async {
    if (!installed) return const [];
    final out = <TermWindow>[];
    final clients = <String, String>{};
    for (final MapEntry(key: name, value: path) in _sockets().entries) {
      try {
        out.addAll(parseTmuxPanes(name, await _run(path, ['list-panes', '-a', '-F', _format]), procs));
        final list = await _run(path, ['list-clients', '-F', '#{client_tty}\t#{pane_id}']);
        clients.addAll(parseTmuxClients(name, list));
      } on TerminalException {
        // A socket left behind by a server that has gone.
        continue;
      }
    }
    this.clients = clients;
    return out;
  }

  @override
  Future<List<String>> lines(String key, {bool history = false}) async {
    final (socket, pane) = _parse(key);
    return screenLines(
      await _run(socket, [
        'capture-pane',
        '-p',
        '-e',
        '-t',
        pane,
        if (history) ...['-S', '-'],
      ]),
    );
  }

  @override
  Future<String> plainScreen(String key) async {
    final (socket, pane) = _parse(key);
    return (await _run(socket, ['capture-pane', '-p', '-t', pane])).trimRight();
  }

  @override
  Future<void> type(String key, String text) async {
    final (socket, pane) = _parse(key);
    await _run(socket, ['send-keys', '-t', pane, '-l', '--', text]);
  }

  @override
  Future<void> pressKeys(String key, List<String> names) async {
    if (names.isEmpty) return;
    final (socket, pane) = _parse(key);
    for (final run in tmuxKeyRuns(names)) {
      await _run(socket, [
        'send-keys',
        '-t',
        pane,
        if (run.literal) ...['-l', '--'],
        ...run.keys,
      ]);
    }
  }

  @override
  Future<void> close(String key) async {
    final (socket, pane) = _parse(key);
    await _run(socket, ['kill-pane', '-t', pane]);
  }

  /// A detached session of its own on the default server (started if none
  /// runs): a terminal app then shows it with `tmux attach` ([attach]).
  @override
  Future<String> launch(String cwd, {List<String>? command}) async {
    if (!Directory(cwd).existsSync()) throw TerminalException('No such folder: $cwd');
    final exe = _exe;
    if (exe == null) throw const TerminalException('tmux is not installed. Install it with: brew install tmux');
    final session = 'dzep-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final r = await Process.run(exe, [
      'new-session',
      '-d',
      '-s',
      session,
      '-c',
      cwd,
      '-P',
      '-F',
      '#{socket_path}\t#{pane_id}',
      ...?command,
    ]);
    if (r.exitCode != 0) throw TerminalException('tmux: ${'${r.stderr}'.trim()}');
    final [path, pane] = (r.stdout as String).trim().split('\t');
    learn(path);
    lastSession = session;
    return 'tmux:${path.split('/').last}/${pane.replaceFirst('%', '')}';
  }

  /// The session [launch] made last.
  String? lastSession;

  /// What a terminal app runs to show tmux session [session].
  List<String> attach(String session) => [_exe ?? 'tmux', 'attach-session', '-t', '=$session'];
}

/// tmux's `list-panes -a -F Tmux._format` output (server [socket]) as windows.
List<TermWindow> parseTmuxPanes(String socket, String out, [Procs? procs]) => [
  for (final line in out.split('\n'))
    if (line.split('\t') case [
      final id,
      final tty,
      final command,
      final path,
      final title,
      final window,
      final session,
      final paneActive,
      final windowActive,
      final attached,
    ])
      () {
        final fg = procs?.foreground(tty);
        final program = fg?.program ?? command;
        return TermWindow(
          key: 'tmux:$socket/${id.replaceFirst('%', '')}',
          // A pane's default title is the host name: its window's name says more.
          title: title.isEmpty || title == Platform.localHostname ? window : title,
          tab: '$session:$window',
          cwd: path,
          program: program,
          focused: paneActive == '1' && windowActive == '1' && attached != '0',
          app: 'tmux',
          tty: tty.replaceFirst('/dev/', ''),
        );
      }(),
];

/// `list-clients -F '#{client_tty}\t#{pane_id}'` as client tty → pane key.
Map<String, String> parseTmuxClients(String socket, String out) => {
  for (final line in out.split('\n'))
    if (line.split('\t') case [final tty, final pane] when pane.startsWith('%'))
      tty.replaceFirst('/dev/', ''): 'tmux:$socket/${pane.substring(1)}',
};

/// kitty's key names as tmux's `send-keys` runs: tmux's names where it has
/// them (so it sends what the program in the pane expects), in one run;
/// a character goes literally (`-l`) in a run of its own, as tmux would
/// read `;` or a word like `Up` as something else. Shift+Enter is Alt+Enter
/// (M-Enter): tmux sends Shift+Enter like Enter unless extended keys are on.
List<({bool literal, List<String> keys})> tmuxKeyRuns(List<String> names) {
  final runs = <({bool literal, List<String> keys})>[];
  void add(String key, {required bool literal}) {
    final last = runs.lastOrNull;
    if (last != null && last.literal == literal) {
      last.keys.add(key);
    } else {
      runs.add((literal: literal, keys: [key]));
    }
  }

  for (final n in names) {
    final named = switch (n) {
      'enter' || 'return' => 'Enter',
      'esc' || 'escape' => 'Escape',
      'tab' => 'Tab',
      'shift+tab' => 'BTab',
      'space' => 'Space',
      'backspace' => 'BSpace',
      'delete' => 'DC',
      'up' => 'Up',
      'down' => 'Down',
      'left' => 'Left',
      'right' => 'Right',
      'home' => 'Home',
      'end' => 'End',
      'page_up' || 'pageup' => 'PPage',
      'page_down' || 'pagedown' => 'NPage',
      'shift+enter' || 'alt+enter' => 'M-Enter',
      _ when RegExp(r'^ctrl\+[a-z]$').hasMatch(n) => 'C-${n.substring(5)}',
      _ => null,
    };
    if (named != null) {
      add(named, literal: false);
    } else if (n.runes.length == 1) {
      add(n, literal: true);
    } else {
      throw TerminalException('Unknown key: $n');
    }
  }
  return runs;
}
