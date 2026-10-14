import 'dart:async';
import 'dart:io';

import 'package:dzep_core/terminal.dart';

/// iTerm2, through its AppleScript dictionary (no setting to turn on; macOS
/// asks once whether Džep may control iTerm2). Its sessions give their id,
/// tty, name and screen text (plain, the visible screen only); `write text`
/// types without a paste, so keys go as the bytes a terminal sends. Window
/// keys: `iterm:<session UUID>` (ITERM_SESSION_ID's second half).
class ITerm extends TerminalHost {
  ITerm({this.appPath = '/Applications/iTerm.app'});

  final String appPath;

  @override
  String get id => 'iterm';

  @override
  String get label => 'iTerm2';

  @override
  String? get appName => 'iTerm2';

  @override
  String? get bundleId => 'com.googlecode.iterm2';

  @override
  Set<TermCap> get caps => const {TermCap.read, TermCap.type, TermCap.line, TermCap.keys, TermCap.close};

  @override
  String get limits => 'Screens come without colors.';

  @override
  bool owns(String key) => key.startsWith('iterm:');

  bool get installed => Directory(appPath).existsSync();
  bool _running(Procs procs) => procs.running('$appPath/Contents/MacOS/');

  Future<String> _osa(String script, [List<String> args = const []]) => runAppleScript(label, bundleId!, script, args);

  /// Finds the session whose id is argv's first item as `s`, then runs [body].
  static String _withSession(String body) =>
      '''
on run argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if id of s is (item 1 of argv) then
$body
            return ""
          end if
        end repeat
      end repeat
    end repeat
  end tell
  error "gone" number -1728
end run''';

  String _session(String key) {
    final id = RegExp(r'^iterm:([0-9A-Fa-f-]{36})$').firstMatch(key)?[1];
    if (id == null) throw const TerminalException('That window is gone.');
    return id;
  }

  Future<String> _on(String key, String body, [List<String> args = const []]) async {
    try {
      return await _osa(_withSession(body), [_session(key), ...args]);
    } on AutomationDenied {
      rethrow;
    } on TerminalException catch (e) {
      if (e.message.contains('gone') || e.message.contains('-1728')) {
        throw const TerminalException('That window is gone.');
      }
      rethrow;
    }
  }

  static const _list = '''
set sep to ASCII character 9
set out to ""
tell application "iTerm2"
  set wi to 0
  repeat with w in windows
    -- A window closing has no current session for a moment: skip it.
    set cur to missing value
    try
      set cur to id of current session of w
    end try
    if cur is not missing value then
      set wi to wi + 1
      set ti to 0
      repeat with t in tabs of w
        set ti to ti + 1
        repeat with s in sessions of t
          set out to out & (id of s) & sep & (tty of s) & sep & (name of s) & sep & wi & sep & ti & sep & ((id of s) is cur) & linefeed
        end repeat
      end repeat
    end if
  end repeat
  set out to out & "front" & sep & frontmost
end tell
return out''';

  @override
  Future<TermStatus> status(Procs procs) async {
    if (!installed) return TermStatus(id, label, TermState.missing);
    if (!_running(procs)) return TermStatus(id, label, TermState.idle, note: 'Not running');
    try {
      final n = (await windows(procs)).length;
      return TermStatus(id, label, TermState.limited, note: '$n window${n == 1 ? '' : 's'} · $limits');
    } on AutomationDenied catch (e) {
      return TermStatus(id, label, TermState.setup, note: e.message, fix: TermFix.automation);
    } on AutomationPending catch (e) {
      return TermStatus(id, label, TermState.setup, note: e.message);
    }
  }

  @override
  Future<List<TermWindow>> windows(Procs procs) async {
    if (!_running(procs)) return const [];
    final out = parseITermList(await _osa(_list), procs);
    final cwds = await Procs.cwds([
      for (final w in out)
        if (procs.foreground(w.tty) case final p?) p.pid,
    ]);
    return [
      for (final w in out)
        TermWindow(
          key: w.key,
          title: w.title,
          tab: w.tab,
          cwd: cwds[procs.foreground(w.tty)?.pid] ?? '',
          program: w.program,
          focused: w.focused,
          app: id,
          caps: caps,
          tty: w.tty,
        ),
    ];
  }

  /// iTerm2's `contents` is the scrollback and the screen, each line padded
  /// with a space; the screen is its last `rows` lines.
  Future<(int rows, List<String> lines)> _contents(String key) async {
    final out = await _on(key, '            return ((rows of s) as text) & linefeed & (contents of s)');
    final [rows, ...lines] = out.replaceFirst(RegExp(r'(\r?\n|\r)$'), '').split(RegExp(r'\r?\n|\r'));
    return (int.tryParse(rows) ?? 24, [for (final l in lines) l.trimRight()]);
  }

  @override
  Future<List<String>> lines(String key, {bool history = false}) async {
    final (rows, lines) = await _contents(key);
    return screenLines((history || lines.length <= rows ? lines : lines.sublist(lines.length - rows)).join('\n'));
  }

  @override
  Future<String> plainScreen(String key) async {
    final (rows, lines) = await _contents(key);
    return (lines.length <= rows ? lines : lines.sublist(lines.length - rows)).join('\n').trimRight();
  }

  @override
  Future<Map<String, Object>?> colors(String key) async {
    const names = [
      'foreground color', 'background color', //
      'ANSI black color', 'ANSI red color', 'ANSI green color', 'ANSI yellow color',
      'ANSI blue color', 'ANSI magenta color', 'ANSI cyan color', 'ANSI white color',
      'ANSI bright black color', 'ANSI bright red color', 'ANSI bright green color', 'ANSI bright yellow color',
      'ANSI bright blue color', 'ANSI bright magenta color', 'ANSI bright cyan color', 'ANSI bright white color',
    ];
    final body = [
      '            set c to {}',
      for (final n in names) '            set c to c & ($n of s)',
      "            set AppleScript's text item delimiters to \",\"",
      '            return c as text',
    ].join('\n');
    final values = [for (final v in (await _on(key, body)).split(',')) int.tryParse(v.trim()) ?? 0];
    if (values.length != names.length * 3) return null;
    int rgb(int i) => (values[i * 3] >> 8) << 16 | (values[i * 3 + 1] >> 8) << 8 | values[i * 3 + 2] >> 8;
    return {
      'fg': rgb(0),
      'bg': rgb(1),
      'palette': [for (var i = 0; i < 16; i++) rgb(i + 2), for (var i = 16; i < 256; i++) xtermRgb(i)],
    };
  }

  /// `write text` with newline off: typed as is (no bracketed paste).
  Future<void> _write(String key, String bytes) =>
      _on(key, '            tell s to write text (item 2 of argv) newline no', [bytes]);

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
  Future<void> close(String key) => _on(key, '            close s');

  /// A new tab in iTerm2's front window (a new window would bring iTerm2 to
  /// the front), or a new window if it has none; the shell then goes to
  /// [cwd] (iTerm2 can't be told a folder by script). iTerm2 comes to the
  /// front as it starts or opens a window, even when told not to: the app
  /// that was in front gets it back.
  @override
  Future<String> launch(String cwd, {List<String>? command}) async {
    if (!Directory(cwd).existsSync()) throw TerminalException('No such folder: $cwd');
    final out = await keepFront(() => _open(command), app: bundleId);
    final key = 'iterm:$out';
    if (command == null) await type(key, ' cd -- ${shellQuote(cwd)} && clear\r');
    return key;
  }

  /// iTerm2's first window when Džep started iTerm2 and no launch has used
  /// it yet (one failed while macOS asked whether Džep may control iTerm2,
  /// say): the next launch takes it rather than leave it empty.
  bool _spare = false;

  /// The new session's id.
  Future<String> _open(List<String>? command) async {
    Future<int> windows() async => int.tryParse(await _osa(_shownWindows)) ?? 0;
    // Not running, or no window: Launch Services opens it (or reopens it) in
    // the background with a first window of its own, which then is the new
    // one. `create window` with no window there makes one that never shows.
    if (!_running(await Procs.snapshot()) || await windows() == 0) {
      await Process.run('/usr/bin/open', ['-g', '-a', appPath]);
      _spare = true;
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (_running(await Procs.snapshot()) && await windows() > 0) break;
      }
    }
    final run = command == null ? '' : ' command (item 2 of argv)';
    // If iTerm2 is set to open no window, one is made here; it can answer
    // missing value while the window still comes: then it's the one that
    // wasn't there before.
    final script =
        '''
on run argv
  tell application "iTerm2"
    set tw to missing value
    repeat with x in windows
      try
        get id of current session of x
        set tw to contents of x
        exit repeat
      end try
    end repeat
    if tw is not missing value then
      -- The window Launch Services just opened is ours, unless iTerm2 restored
      -- an old session into it: one with more than a prompt is never reused.
      if (item 1 of argv) is "fresh" and "$run" is "" and (count of windows) is 1 then
        if (length of (contents of current session of tw)) < 400 then return id of current session of tw
      end if
      tell tw to set t to (create tab with default profile$run)
      return id of current session of t
    end if
    set known to id of every window
    set w to (create window with default profile$run)
    repeat 30 times
      if w is not missing value then exit repeat
      delay 0.1
      repeat with x in windows
        if known does not contain (id of x) then set w to contents of x
      end repeat
    end repeat
    return id of current session of w
  end tell
end run''';
    final id = await _osa(script, [
      if (_spare) 'fresh' else '',
      if (command != null) command.map(shellQuote).join(' '),
    ]);
    _spare = false;
    return id;
  }

  /// How many windows have a session (one that never showed has none).
  static const _shownWindows = '''
tell application "iTerm2"
  set n to 0
  repeat with x in windows
    try
      get id of current session of x
      set n to n + 1
    end try
  end repeat
  return n
end tell''';
}

/// The listing script's output: a line per session (id, tty, name, window
/// index, tab index, whether it's its window's current one), then
/// `front<TAB>true|false`.
List<TermWindow> parseITermList(String out, [Procs? procs]) {
  final lines = out.split(RegExp(r'\r?\n|\r'));
  final front = lines.any((l) => l == 'front\ttrue');
  return [
    for (final l in lines)
      if (l.split('\t') case [final id, final tty, final name, final window, final tab, final current])
        TermWindow(
          key: 'iterm:$id',
          title: name,
          tab: 'Tab $tab',
          cwd: '',
          program: procs?.foreground(tty)?.program ?? '',
          focused: front && window == '1' && current == 'true',
          app: 'iterm',
          tty: tty.replaceFirst('/dev/', ''),
        ),
  ];
}
