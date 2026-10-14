import 'dart:async';
import 'dart:io';

import 'package:dzep_core/terminal.dart';

/// Ghostty (1.3 and later), through its AppleScript dictionary (macOS asks
/// once whether Džep may control Ghostty). Its terminals give an id, a
/// title and a folder; its `text:` action writes bytes to one as typed
/// (its `input text` would paste); new windows take a folder and a command
/// and stay behind. It has no tty to tell and no way to read a screen but
/// through the clipboard or a file it opens, so its windows can't be read;
/// the phone's sessions there run in tmux when it's installed. Window keys:
/// `ghostty:<terminal UUID>`.
class Ghostty extends TerminalHost {
  Ghostty({this.appPath = '/Applications/Ghostty.app'});

  final String appPath;

  @override
  String get id => 'ghostty';

  @override
  String get label => 'Ghostty';

  @override
  String? get appName => 'Ghostty';

  @override
  String? get bundleId => 'com.mitchellh.ghostty';

  @override
  Set<TermCap> get caps => const {TermCap.type, TermCap.line, TermCap.keys, TermCap.close};

  @override
  String get limits => "Ghostty can't share its screen.";

  @override
  bool owns(String key) => key.startsWith('ghostty:');

  bool get installed => Directory(appPath).existsSync();
  bool _running(Procs procs) => procs.running('$appPath/Contents/MacOS/');

  Future<String> _osa(String script, [List<String> args = const []]) => runAppleScript(label, bundleId!, script, args);

  String _terminal(String key) {
    final id = RegExp(r'^ghostty:([0-9A-Fa-f-]{36})$').firstMatch(key)?[1];
    if (id == null) throw const TerminalException('That window is gone.');
    return id;
  }

  Future<String> _on(String key, String body, [List<String> args = const []]) async {
    try {
      return await _osa(
        '''
on run argv
  tell application "Ghostty"
    set t to first terminal whose id is (item 1 of argv)
$body
  end tell
  return ""
end run''',
        [_terminal(key), ...args],
      );
    } on AutomationDenied {
      rethrow;
    } on TerminalException catch (e) {
      if (e.message.contains('-1719') || e.message.contains('-1728')) {
        throw const TerminalException('That window is gone.');
      }
      rethrow;
    }
  }

  static const _list = '''
set sep to ASCII character 9
set out to ""
tell application "Ghostty"
  set focusedId to ""
  try
    set focusedId to id of focused terminal of selected tab of front window
  end try
  repeat with w in windows
    repeat with b in tabs of w
      repeat with t in terminals of b
        set out to out & (id of t) & sep & (name of t) & sep & (working directory of t) & sep & (name of b) & sep & ((id of t) is focusedId) & linefeed
      end repeat
    end repeat
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
    } on TerminalException catch (e) {
      // Before 1.3 Ghostty had no scripting.
      return TermStatus(id, label, TermState.limited, note: 'Needs Ghostty 1.3 or later (${e.message})');
    }
  }

  /// Its terminals; those whose tty is known ([launch], [learn]) with it
  /// and their foreground program.
  @override
  Future<List<TermWindow>> windows(Procs procs) async {
    if (!_running(procs)) return const [];
    final all = parseGhosttyList(await _osa(_list));
    final listed = {for (final w in all) w.key};
    _ttys.removeWhere((key, _) => !listed.contains(key));
    return [
      for (final w in all)
        if (_ttys[w.key] case final tty?)
          TermWindow(
            key: w.key,
            title: w.title,
            tab: w.tab,
            cwd: w.cwd,
            program: procs.foreground(tty)?.program ?? '',
            focused: w.focused,
            app: w.app,
            caps: w.caps,
            tty: tty,
          )
        else
          w,
    ];
  }

  /// Through Ghostty's `text:` action: bytes to the program as if typed.
  Future<void> _write(String key, String bytes) =>
      _on(key, '    perform action (item 2 of argv) on t', ['text:${ghosttyText(bytes)}']);

  @override
  Future<void> type(String key, String text) => _write(key, text);

  @override
  Future<void> pressKeys(String key, List<String> names) async {
    for (final (i, run) in keyRuns(names).indexed) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 40));
      await _write(key, run);
    }
  }

  /// Ghostty tells no tty, so the ones of windows Džep opened (and of
  /// windows an agent named its tty in) are kept here: key → `ttys012`.
  final _ttys = <String, String>{};

  /// The ttys of Ghostty's terminals now: its children's (a login each).
  Set<String> _surfaceTtys(Procs procs) {
    final ghostty = procs.pidOf('$appPath/Contents/MacOS/');
    return {
      for (final p in procs.all)
        if (ghostty != null && p.ppid == ghostty && p.tty.isNotEmpty) p.tty,
    };
  }

  /// [key]'s tty is [tty] (an agent there said so).
  void learn(String key, String tty) => _ttys[key] = tty.replaceFirst('/dev/', '');

  /// The window on [tty], when it's one whose tty is known.
  String? byTty(String tty) {
    final t = tty.replaceFirst('/dev/', '');
    return _ttys.entries.where((e) => e.value == t).firstOrNull?.key;
  }

  /// What runs on its tty ends first where the tty is known (Ghostty would
  /// ask on the Mac whether to close a window something runs in; with
  /// nothing left it closes it itself). Ghostty comes to the front when it
  /// closes a window while in the background (or starts, below): the app
  /// that was in front gets it back.
  @override
  Future<void> close(String key) => keepFront(() async {
    final tty = _ttys.remove(key);
    if (tty != null) {
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
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    try {
      await _on(key, '    close t');
    } on TerminalException catch (e) {
      // Closed by itself once its shell ended.
      if (tty == null || e.message != 'That window is gone.') rethrow;
    }
  }, app: bundleId);

  /// The id of the Ghostty window Džep opened last.
  String? _window;

  /// A new tab in [cwd] in the Ghostty window Džep opened last, or a new
  /// window (it stays behind the app in front) if that one is gone, running
  /// the shell, or [command] in place of it. Ghostty comes to the front for
  /// a new window (the app that was in front gets it back), not for a tab.
  @override
  Future<String> launch(String cwd, {List<String>? command}) async {
    if (!Directory(cwd).existsSync()) throw TerminalException('No such folder: $cwd');
    final before = _surfaceTtys(await Procs.snapshot());
    final out = await keepFront(
      () => _osa(
        '''
on run argv
  set sep to ASCII character 9
  tell application "Ghostty"
    set cfg to new surface configuration
    set initial working directory of cfg to (item 1 of argv)
    if (item 2 of argv) is not "" then set command of cfg to (item 2 of argv)
    repeat with w in windows
      if (id of w) is (item 3 of argv) then
        set b to new tab in w with configuration cfg
        return (item 3 of argv) & sep & (id of focused terminal of b)
      end if
    end repeat
    set w to new window with configuration cfg
    return (id of w) & sep & (id of focused terminal of selected tab of w)
  end tell
end run''',
        [cwd, if (command != null) command.map(shellQuote).join(' ') else '', _window ?? ''],
      ),
      app: bundleId,
    );
    final [window, id] = out.split('\t');
    _window = window;
    final key = 'ghostty:$id';
    // Its tty: the one new among Ghostty's terminals.
    for (var i = 0; i < 20; i++) {
      final added = _surfaceTtys(await Procs.snapshot()).difference(before);
      if (added.length == 1) {
        _ttys[key] = added.single;
        break;
      }
      if (added.length > 1) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return key;
  }

  /// The terminal whose folder is [cwd], if exactly one is: where an agent
  /// reporting that folder runs, when its tty isn't one known.
  Future<String?> byFolder(String cwd, Procs procs) async {
    if (cwd.isEmpty) return null;
    final List<TermWindow> all;
    try {
      all = await windows(procs);
    } on TerminalException {
      return null;
    }
    final here = all.where((w) => w.cwd == cwd || w.cwd == '/private$cwd').toList();
    return here.length == 1 ? here.single.key : null;
  }
}

/// The listing script's output: a line per terminal (id, title, folder,
/// tab title, focused), then `front<TAB>true|false`.
List<TermWindow> parseGhosttyList(String out) {
  final lines = out.split(RegExp(r'\r?\n|\r'));
  final front = lines.any((l) => l == 'front\ttrue');
  return [
    for (final l in lines)
      if (l.split('\t') case [final id, final title, final cwd, final tab, final focused] when id != 'front')
        TermWindow(
          key: 'ghostty:$id',
          title: title,
          tab: tab,
          cwd: cwd,
          program: '',
          focused: front && focused == 'true',
          app: 'ghostty',
          caps: const {TermCap.type, TermCap.line, TermCap.keys, TermCap.close},
        ),
  ];
}

/// [bytes] as the argument of Ghostty's `text:` action, which reads it as
/// a Zig string literal's body: a backslash and a quote escaped, anything
/// below space (and DEL) as `\xNN`.
String ghosttyText(String bytes) {
  final out = StringBuffer();
  for (final c in bytes.runes) {
    if (c == 0x5c) {
      out.write(r'\\');
    } else if (c == 0x22) {
      out.write(r'\"');
    } else if (c < 0x20 || c == 0x7f) {
      out.write('\\x${c.toRadixString(16).padLeft(2, '0')}');
    } else {
      out.writeCharCode(c);
    }
  }
  return '$out';
}
