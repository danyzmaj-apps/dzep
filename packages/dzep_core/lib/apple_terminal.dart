import 'dart:async';
import 'dart:io';

import 'package:dzep_core/terminal.dart';

/// macOS's Terminal, through its AppleScript dictionary (macOS asks once
/// whether Džep may control Terminal). A tab gives its tty and its text,
/// scrollback included; `do script` runs a line in it (always with Enter),
/// and there is no way to press a key without System Events, which Džep
/// doesn't use. So its windows can be read and given whole lines, nothing
/// more; the phone's sessions there run in tmux when it's installed. Window
/// keys: `terminal:<tty>`.
class AppleTerminal extends TerminalHost {
  AppleTerminal({this.appPath = '/System/Applications/Utilities/Terminal.app'});

  final String appPath;

  @override
  String get id => 'terminal';

  @override
  String get label => 'Terminal';

  @override
  String? get appName => 'Terminal';

  @override
  String? get bundleId => 'com.apple.Terminal';

  @override
  Set<TermCap> get caps => const {TermCap.read, TermCap.line, TermCap.close};

  @override
  String get limits => "Terminal can't press keys (arrows, Esc) or type without Enter.";

  @override
  bool owns(String key) => key.startsWith('terminal:');

  bool get installed => Directory(appPath).existsSync();
  bool _running(Procs procs) => procs.running('$appPath/Contents/MacOS/');

  Future<String> _osa(String script, [List<String> args = const []]) => runAppleScript(label, bundleId!, script, args);

  String _tty(String key) {
    final tty = RegExp(r'^terminal:(ttys\d+)$').firstMatch(key)?[1];
    if (tty == null) throw const TerminalException('That window is gone.');
    return tty;
  }

  /// Finds the tab on argv's first item's tty, then runs [body], which
  /// names it `tab j of window i`: a variable would hold a reference, and
  /// `contents` of a reference is the reference.
  static String _withTab(String body) =>
      '''
on run argv
  tell application "Terminal"
    repeat with i from 1 to count of windows
      repeat with j from 1 to count of tabs of window i
        if tty of tab j of window i is ("/dev/" & item 1 of argv) then
$body
          return ""
        end if
      end repeat
    end repeat
  end tell
  error "gone" number -1728
end run''';

  Future<String> _on(String key, String body, [List<String> args = const []]) async {
    try {
      return await _osa(_withTab(body), [_tty(key), ...args]);
    } on AutomationDenied {
      rethrow;
    } on TerminalException catch (e) {
      if (e.message.contains('gone') || e.message.contains('-1728')) {
        throw const TerminalException('That window is gone.');
      }
      rethrow;
    }
  }

  /// A window counts when it shows, or when Terminal is hidden (launched by
  /// a script, or ⌘H) and its first tab still runs something: an invisible
  /// window with nothing running is one Terminal is done with.
  static const _list = '''
set sep to ASCII character 9
set out to ""
tell application "Terminal"
  set wi to 0
  repeat with i from 1 to count of windows
    set shown to false
    try
      set shown to (visible of window i) or ((count of processes of tab 1 of window i) > 0)
    end try
    if shown then
      set wi to wi + 1
      repeat with j from 1 to count of tabs of window i
        set t to tab j of window i
        set out to out & (tty of t) & sep & (name of window i) & sep & wi & sep & j & sep & (selected of t) & sep & (custom title of t) & linefeed
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
    final out = parseTerminalList(await _osa(_list), procs);
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

  @override
  Future<List<String>> lines(String key, {bool history = false}) async =>
      screenLines(await _on(key, '          return ${history ? 'history' : 'contents'} of tab j of window i'));

  @override
  Future<String> plainScreen(String key) async =>
      (await _on(key, '          return contents of tab j of window i')).trimRight();

  /// `do script` runs its text as a line: Enter always follows.
  @override
  Future<void> send(String key, String text, {required bool enter}) async {
    if (!enter) throw const TerminalException("Terminal can't type without pressing Enter. $_tmuxHint");
    await _on(key, '          do script (item 2 of argv) in tab j of window i', [text]);
  }

  @override
  Future<void> type(String key, String text) =>
      throw const TerminalException("Terminal can't type without pressing Enter. $_tmuxHint");

  /// Enter alone is an empty line; any other key can't be pressed.
  @override
  Future<void> pressKeys(String key, List<String> names) async {
    if (names.every((n) => n == 'enter')) {
      for (final _ in names) {
        await send(key, '', enter: true);
      }
      return;
    }
    throw const TerminalException("Terminal can't press keys like arrows or Esc. $_tmuxHint");
  }

  static const _tmuxHint = 'Start the session from your phone to run it in tmux (brew install tmux).';

  /// Ends what runs on its tty (Terminal would otherwise ask on the Mac
  /// whether to), then closes its window if that was its only tab.
  @override
  Future<void> close(String key) async {
    final tty = _tty(key);
    // Its window, found while the tab still has its tty: `<id> <tab count>`.
    final [window, tabs] = (await _on(
      key,
      '          return ((id of window i) as text) & " " & (count of tabs of window i)',
    )).split(' ');
    Future<List<int>> onTty() async => [
      for (final w in '${(await Process.run('/bin/ps', ['-t', tty, '-o', 'pid='])).stdout}'.split(RegExp(r'\s+')))
        ?int.tryParse(w),
    ];
    for (final pid in await onTty()) {
      Process.killPid(pid, ProcessSignal.sighup);
    }
    for (var i = 0; i < 20 && (await onTty()).isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // A window of several tabs keeps this one, its process ended: scripts
    // can't close a tab.
    if (tabs != '1') return;
    await _osa('on run argv\n  tell application "Terminal" to close window id ((item 1 of argv) as integer)\nend run', [
      window,
    ]);
  }

  /// Terminal's first window when Džep started Terminal and no launch has
  /// used it yet (one failed while macOS asked whether Džep may control
  /// Terminal, say): the next launch takes it rather than leave it empty.
  bool _spare = false;

  /// A new Terminal window (it stays behind the app in front) in [cwd],
  /// running the shell, or [command] in place of it. A Terminal a script
  /// starts stays hidden, so one that isn't running is opened in the
  /// background first, and the window it opens with (when it's the only
  /// one, idle and not restored from before) is used rather than left empty.
  @override
  Future<String> launch(String cwd, {List<String>? command}) async {
    if (!Directory(cwd).existsSync()) throw TerminalException('No such folder: $cwd');
    final line = [
      ' cd -- ${shellQuote(cwd)}',
      if (command != null) 'exec ${command.map(shellQuote).join(' ')}' else 'clear',
    ].join(' && ');
    if (!_running(await Procs.snapshot())) {
      await Process.run('/usr/bin/open', ['-g', '-a', appPath]);
      _spare = true;
      for (var i = 0; i < 50; i++) {
        if (_running(await Procs.snapshot()) && await _osa('tell application "Terminal" to count of windows') != '0') {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    final tty = await _osa(
      '''
on run argv
  tell application "Terminal"
    if item 2 of argv is "fresh" and (count of windows) is 1 then
      set t to selected tab of window 1
      if not busy of t and history of t does not contain "Restored session" then
        do script (item 1 of argv) in t
        return tty of t
      end if
    end if
    set t to do script (item 1 of argv)
    return tty of t
  end tell
end run''',
      [line, if (_spare) 'fresh' else 'running'],
    );
    _spare = false;
    return 'terminal:${tty.replaceFirst('/dev/', '')}';
  }
}

/// The listing script's output: a line per tab (tty, window name, window
/// index, tab index, selected, custom title), then `front<TAB>true|false`.
List<TermWindow> parseTerminalList(String out, [Procs? procs]) {
  final lines = out.split(RegExp(r'\r?\n|\r'));
  final front = lines.any((l) => l == 'front\ttrue');
  return [
    for (final l in lines)
      if (l.split('\t') case [final tty, final name, final window, final tab, final selected, final custom]
          when tty.startsWith('/dev/'))
        TermWindow(
          key: 'terminal:${tty.replaceFirst('/dev/', '')}',
          title: custom.isNotEmpty ? custom : name.split(' — ').first,
          tab: 'Tab $tab',
          cwd: '',
          program: procs?.foreground(tty)?.program ?? '',
          focused: front && window == '1' && selected == 'true',
          app: 'terminal',
          tty: tty.replaceFirst('/dev/', ''),
        ),
  ];
}
