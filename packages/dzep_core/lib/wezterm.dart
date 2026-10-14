import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dzep_core/terminal.dart';

/// WezTerm, through `wezterm cli` against each running GUI's socket
/// (`~/.local/share/wezterm/gui-sock-<pid>`). Window keys:
/// `wezterm:<gui pid>/<pane id>`.
class WezTerm extends TerminalHost {
  WezTerm({String? executable, String? socketDir, String? home})
    : _exe = executable ?? findExecutable('wezterm', extra: const ['/Applications/WezTerm.app/Contents/MacOS/wezterm']),
      _dir = socketDir ?? '${home ?? Platform.environment['HOME'] ?? ''}/.local/share/wezterm';

  final String? _exe;
  final String _dir;

  @override
  String get id => 'wezterm';

  @override
  String get label => 'WezTerm';

  @override
  String? get appName => 'WezTerm';

  @override
  String? get bundleId => 'com.github.wez.wezterm';

  @override
  Set<TermCap> get caps => allCaps;

  @override
  bool owns(String key) => key.startsWith('wezterm:');

  bool get installed => _exe != null && File(_exe).existsSync();

  /// GUI pid → its socket, for each socket whose GUI still runs.
  Map<String, String> _sockets(Procs? procs) {
    final d = Directory(_dir);
    if (!d.existsSync()) return const {};
    final out = <String, String>{};
    for (final e in d.listSync(followLinks: false)) {
      final m = RegExp(r'^gui-sock-(\d+)$').firstMatch(e.uri.pathSegments.last);
      if (m == null) continue;
      if (procs != null && procs.byPid(int.parse(m[1]!)) == null) continue;
      out[m[1]!] = e.path;
    }
    return out;
  }

  Future<String> _cli(String socket, List<String> args) async {
    final exe = _exe;
    if (exe == null) throw const TerminalException('WezTerm is not installed.');
    final ProcessResult r;
    try {
      r = await Process.run(
        exe,
        ['cli', '--no-auto-start', ...args],
        environment: {'WEZTERM_UNIX_SOCKET': socket},
      ).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      throw const TerminalException('WezTerm did not answer.');
    }
    if (r.exitCode != 0) {
      final err = '${r.stderr}'.trim();
      if (err.contains('is not valid') || err.contains('pane') && err.contains('not found')) {
        throw const TerminalException('That window is gone.');
      }
      throw TerminalException('WezTerm: ${err.split('\n').last}');
    }
    return r.stdout as String;
  }

  (String socket, String pane) _parse(String key) {
    final m = RegExp(r'^wezterm:(\d+)/(\d+)$').firstMatch(key);
    final socket = m == null ? null : _sockets(null)[m[1]];
    if (socket == null) throw const TerminalException('That window is gone.');
    return (socket, m![2]!);
  }

  @override
  Future<TermStatus> status(Procs procs) async {
    if (!installed) return TermStatus(id, label, TermState.missing);
    if (_sockets(procs).isEmpty) return TermStatus(id, label, TermState.idle, note: 'Not running');
    final n = (await windows(procs)).length;
    return TermStatus(id, label, TermState.ready, note: '$n window${n == 1 ? '' : 's'}');
  }

  @override
  Future<List<TermWindow>> windows(Procs procs) async {
    final out = <TermWindow>[];
    for (final MapEntry(key: pid, value: socket) in _sockets(procs).entries) {
      final String json;
      try {
        json = await _cli(socket, ['list', '--format', 'json']);
      } on TerminalException {
        continue;
      }
      out.addAll(parseWezTermList(pid, json, procs));
    }
    // The foreground program's own folder, where the shell's report is older.
    final cwds = await Procs.cwds([
      for (final w in out)
        if (procs.foreground(w.tty) case final p?) p.pid,
    ]);
    return [
      for (final w in out)
        if (cwds[procs.foreground(w.tty)?.pid] case final cwd?)
          TermWindow(
            key: w.key,
            title: w.title,
            tab: w.tab,
            cwd: cwd,
            program: w.program,
            focused: w.focused,
            app: w.app,
            caps: w.caps,
            tty: w.tty,
          )
        else
          w,
    ];
  }

  @override
  Future<List<String>> lines(String key, {bool history = false}) async {
    final (socket, pane) = _parse(key);
    return screenLines(
      await _cli(socket, [
        'get-text',
        '--pane-id',
        pane,
        '--escapes',
        if (history) ...['--start-line', '-10000'],
      ]),
    );
  }

  @override
  Future<String> plainScreen(String key) async {
    final (socket, pane) = _parse(key);
    return (await _cli(socket, ['get-text', '--pane-id', pane])).trimRight();
  }

  /// `--no-paste`: as typed, not a bracketed paste.
  Future<void> _write(String key, String bytes) async {
    final (socket, pane) = _parse(key);
    await _cli(socket, ['send-text', '--pane-id', pane, '--no-paste', '--', bytes]);
  }

  @override
  Future<void> type(String key, String text) => _write(key, text);

  @override
  Future<void> pressKeys(String key, List<String> names) async {
    for (final (i, run) in keyRuns(names).indexed) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 40));
      await _write(key, run);
    }
  }

  @override
  Future<void> close(String key) async {
    final (socket, pane) = _parse(key);
    await _cli(socket, ['kill-pane', '--pane-id', pane]);
  }

  /// A new tab in WezTerm's newest window (a new window would take the
  /// focus), or a new window if it has none. A WezTerm not running is
  /// started in the background, and its first window is the new one.
  @override
  Future<String> launch(String cwd, {List<String>? command}) async {
    if (!Directory(cwd).existsSync()) throw TerminalException('No such folder: $cwd');
    var sockets = _sockets(await Procs.snapshot());
    final fresh = sockets.isEmpty;
    if (fresh) {
      await Process.run('/usr/bin/open', ['-g', '-a', 'WezTerm']);
      for (var i = 0; i < 40 && sockets.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        sockets = _sockets(await Procs.snapshot());
      }
      if (sockets.isEmpty) throw const TerminalException("WezTerm didn't start.");
    }
    final MapEntry(key: pid, value: socket) = sockets.entries.last;
    final panes = [
      for (final p in jsonDecode(await _cli(socket, ['list', '--format', 'json'])) as List) p as Map,
    ];
    if (fresh && command == null && panes.length == 1) {
      final key = 'wezterm:$pid/${panes.single['pane_id']}';
      await type(key, ' cd -- ${shellQuote(cwd)} && clear\r');
      return key;
    }
    final newest = panes.isEmpty ? null : panes.map((p) => p['window_id'] as int).reduce(max);
    Future<String> spawn() => _cli(socket, [
      'spawn',
      if (newest != null) ...['--window-id', '$newest'] else '--new-window',
      '--cwd',
      cwd,
      if (command != null) ...['--', ...command],
    ]);
    final pane = (newest != null ? await spawn() : await keepFront(spawn, app: bundleId)).trim();
    return 'wezterm:$pid/$pane';
  }
}

/// `wezterm cli list --format json` (the GUI with pid [pid]) as windows.
List<TermWindow> parseWezTermList(String pid, String json, [Procs? procs]) => [
  for (final p in jsonDecode(json) as List)
    () {
      final pane = p as Map;
      final tty = (pane['tty_name'] as String? ?? '').replaceFirst('/dev/', '');
      final fg = procs?.foreground(tty);
      final cwd = Uri.tryParse(pane['cwd'] as String? ?? '');
      return TermWindow(
        key: 'wezterm:$pid/${pane['pane_id']}',
        title: pane['title'] as String? ?? '',
        tab: pane['tab_title'] as String? ?? '',
        cwd: cwd != null && cwd.scheme == 'file' ? cwd.path : '',
        program: fg?.program ?? '',
        focused: pane['is_active'] == true,
        app: 'wezterm',
        tty: tty,
      );
    }(),
];
