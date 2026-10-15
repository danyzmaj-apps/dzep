import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dzep_core/agent.dart';
import 'package:dzep_core/terminals.dart' show Terminals;

// The Mac's terminals as the phone reaches them (lib/terminals.dart merges
// them): one TerminalHost per terminal app (kitty, iTerm2, WezTerm,
// Terminal, Ghostty) or multiplexer (tmux), each with what its scripting
// can do (TermCap). A window's key starts with its host's prefix and fits
// the push function's session keys, `[\w.:/-]{1,64}`:
//
//   kitty      kitty-<pid>/<window id>       (the socket's name, as before)
//   tmux       tmux:<socket name>/<pane n>   (%n is the pane)
//   wezterm    wezterm:<gui pid>/<pane id>
//   iterm      iterm:<session UUID>
//   terminal   terminal:<tty>                (ttys012)
//   ghostty    ghostty:<terminal UUID>

/// What a window's terminal lets the phone do with it.
enum TermCap {
  /// Its screen can be read (as text, with colors if [ansi]).
  read,

  /// Its screen comes with its colors as ANSI escapes.
  ansi,

  /// Text can be typed without Enter, and Enter and Shift+Enter pressed.
  type,

  /// A line can be typed and run (Enter after it), nothing else: Terminal.
  line,

  /// Keys can be pressed: arrows, Esc, Tab, Ctrl+C, digits.
  keys,

  /// It can be closed.
  close,
}

/// Everything, as an older Mac's windows (kitty's) could.
const Set<TermCap> allCaps = {TermCap.read, TermCap.ansi, TermCap.type, TermCap.line, TermCap.keys, TermCap.close};

/// One terminal window (a tab, a pane, a split: whatever the app calls the
/// thing a shell runs in), as the phone sees it.
class TermWindow {
  const TermWindow({
    required this.key,
    required this.title,
    required this.tab,
    required this.cwd,
    required this.program,
    this.focused = false,
    this.app = 'kitty',
    this.caps = allCaps,
    this.via = '',
    this.tty = '',
  });

  factory TermWindow.fromJson(Map<String, dynamic> j) => TermWindow(
    key: j['key'] as String,
    title: j['title'] as String? ?? '',
    tab: j['tab'] as String? ?? '',
    cwd: j['cwd'] as String? ?? '',
    program: j['program'] as String? ?? '',
    focused: j['focused'] == true,
    // An older Mac lists only kitty, which can do everything.
    app: j['app'] as String? ?? 'kitty',
    caps: j['caps'] is List ? {for (final c in j['caps'] as List) ?TermCap.values.asNameMap()[c]} : allCaps,
    via: j['via'] as String? ?? '',
  );

  /// The host's prefix, then which window of which instance.
  final String key;
  final String title;

  /// The tab's title.
  final String tab;

  /// The foreground program's working directory.
  final String cwd;

  /// The foreground program's name: `omp`, `claude`, `zsh`, `nvim`.
  final String program;

  /// The window its app has focused.
  final bool focused;

  /// Its host's id: kitty, tmux, wezterm, iterm, terminal, ghostty.
  final String app;
  final Set<TermCap> caps;

  /// The terminal app a tmux pane shows in (its client's), by label.
  final String via;

  /// Its tty (`ttys012`), when the app says; the Mac's own business.
  final String tty;

  /// The coding agent running in it, if one is.
  Agent? get agent => Agent.ofProgram(program);

  bool can(TermCap cap) => caps.contains(cap);

  TermWindow copyWith({String? via, Set<TermCap>? caps}) => TermWindow(
    key: key,
    title: title,
    tab: tab,
    cwd: cwd,
    program: program,
    focused: focused,
    app: app,
    caps: caps ?? this.caps,
    via: via ?? this.via,
    tty: tty,
  );

  Map<String, dynamic> toJson() => {
    'key': key,
    'title': title,
    'tab': tab,
    'cwd': cwd,
    'program': program,
    'focused': focused,
    'app': app,
    'caps': [
      for (final c in TermCap.values)
        if (caps.contains(c)) c.name,
    ],
    if (via.isNotEmpty) 'via': via,
  };
}

/// Something a terminal couldn't do, said the way the phone shows it.
class TerminalException implements Exception {
  const TerminalException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// How a terminal stands, for Settings → Terminal.
enum TermState {
  /// Usable: the phone sees its windows and can do what its caps say.
  ready,

  /// Usable, but its scripting can't do everything ([TermStatus.note] says
  /// what's missing).
  limited,

  /// Installed, and needs one thing done first ([TermStatus.fix]).
  setup,

  /// Installed and not running: nothing to list now.
  idle,

  /// Not on this Mac.
  missing,
}

/// The one-click fixes Settings offers.
enum TermFix {
  /// Append kitty's remote control lines to kitty.conf (then restart kitty).
  kittyConfig,

  /// Open System Settings → Privacy & Security → Automation.
  automation,
}

class TermStatus {
  const TermStatus(this.id, this.label, this.state, {this.note = '', this.fix});

  /// As the phone gets it in the bridge's state (without [fix], which only
  /// Settings on the Mac offers); an unknown state reads as limited.
  factory TermStatus.fromJson(Map<String, dynamic> j) => TermStatus(
    j['id'] as String? ?? '',
    j['label'] as String? ?? '',
    TermState.values.asNameMap()[j['state']] ?? TermState.limited,
    note: j['note'] as String? ?? '',
  );

  final String id;
  final String label;
  final TermState state;

  /// One line: what works, what's missing, what to do.
  final String note;
  final TermFix? fix;

  bool get usable => state == TermState.ready || state == TermState.limited;

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'state': state.name, 'note': note};
}

/// One terminal app (or tmux) on this Mac, behind the interface the bridge
/// uses. Keys are always those [owns] accepts.
abstract class TerminalHost {
  /// The key prefix family and the id in Settings: kitty, tmux, wezterm,
  /// iterm, terminal, ghostty.
  String get id;

  /// How people name it: "iTerm2".
  String get label;

  /// What its windows can do.
  Set<TermCap> get caps;

  /// What a window of it can't do, said once for Settings and the phone
  /// (empty: nothing missing).
  String get limits => '';

  /// The name of its app in `lsappinfo visibleProcessList` (null: not an app).
  String? get appName;

  /// Its app's bundle id, for [keepFront] (null: not an app).
  String? get bundleId => null;

  bool owns(String key);

  /// Is it installed / running / reachable; never launches it.
  Future<TermStatus> status(Procs procs);

  /// Every window, in the app's order. Throws when the app can't be asked.
  Future<List<TermWindow>> windows(Procs procs);

  /// What the window shows now (with [history], its scrollback above
  /// too), line by line, with colors as ANSI escapes where it has them.
  Future<List<String>> lines(String key, {bool history = false}) =>
      throw TerminalException("$label can't share its screen.");

  /// What the window shows now as plain text.
  Future<String> plainScreen(String key) => throw TerminalException("$label can't share its screen.");

  /// The window's colors (`{fg, bg, palette}` as 0xRRGGBB), when the app tells.
  Future<Map<String, Object>?> colors(String key) async => null;

  /// Types [text] as keystrokes (not as a paste), without Enter.
  Future<void> type(String key, String text) => throw TerminalException("$label can't type into its windows.");

  /// Presses [names] in order: kitty's key names ([keyBytes] knows them).
  Future<void> pressKeys(String key, List<String> names) =>
      throw TerminalException("$label can't press keys in its windows.");

  /// Types [text], a line break as Shift+Enter (a new line in an agent's
  /// editor; a shell runs the line), then Enter if [enter].
  Future<void> send(String key, String text, {required bool enter}) async {
    for (final (i, line) in text.split('\n').indexed) {
      if (i > 0) await pressKeys(key, const ['shift+enter']);
      if (line.isNotEmpty) await type(key, line);
    }
    if (enter) await pressKeys(key, const ['enter']);
  }

  /// Closes the window and what runs in it.
  Future<void> close(String key) => throw TerminalException("$label can't close its windows.");

  /// A new window (or a tab of its newest window, where a new window would
  /// take the focus) in [cwd] running the login shell, or [command] (argv)
  /// instead; its key. Never takes the focus where the app allows.
  Future<String> launch(String cwd, {List<String>? command});
}

// ------------------------------------------------------------ keys

/// What a key sends to the program in the terminal, for hosts that write
/// bytes. kitty's names: `enter`, `esc`, `tab`, `shift+tab`, `space`,
/// `backspace`, arrows, `ctrl+<letter>`, a single character. Shift+Enter
/// goes as Alt+Enter (ESC CR), which omp's and Claude Code's editors read as
/// a new line where the terminal can't send Shift+Enter itself.
String keyBytes(String name) {
  final named = switch (name) {
    'enter' || 'return' => '\r',
    'esc' || 'escape' => '\x1b',
    'tab' => '\t',
    'shift+tab' => '\x1b[Z',
    'space' => ' ',
    'backspace' => '\x7f',
    'delete' => '\x1b[3~',
    'up' => '\x1b[A',
    'down' => '\x1b[B',
    'right' => '\x1b[C',
    'left' => '\x1b[D',
    'home' => '\x1b[H',
    'end' => '\x1b[F',
    'page_up' || 'pageup' => '\x1b[5~',
    'page_down' || 'pagedown' => '\x1b[6~',
    'shift+enter' || 'alt+enter' => '\x1b\r',
    _ => null,
  };
  if (named != null) return named;
  final ctrl = RegExp(r'^ctrl\+([a-z])$').firstMatch(name);
  if (ctrl != null) return String.fromCharCode(ctrl[1]!.codeUnitAt(0) - 0x60);
  if (name.runes.length == 1) return name;
  throw TerminalException('Unknown key: $name');
}

/// [names] as the byte runs to write: one run, except that Esc goes on its
/// own (followed by more bytes it would read as Alt+key).
List<String> keyRuns(List<String> names) {
  final runs = <String>[];
  var current = StringBuffer();
  for (final n in names) {
    final b = keyBytes(n);
    if (b == '\x1b') {
      if (current.isNotEmpty) runs.add('$current');
      runs.add(b);
      current = StringBuffer();
    } else {
      current.write(b);
    }
  }
  if (current.isNotEmpty) runs.add('$current');
  return runs;
}

/// Keys the phone may press itself (the screen page's key row).
const phoneKeys = {'esc', 'tab', 'up', 'down', 'enter', 'ctrl+c'};

// ------------------------------------------------------------ screens

/// Realtime drops or refuses messages past ~100 KB (one of 180 KB closed the
/// socket), so scrollback keeps only its newest lines up to this many UTF-8
/// bytes.
const historyBytes = 60000;

/// A terminal's [text] as the phone's lines: charset choices (ESC ( B,
/// which WezTerm puts before its SGR resets) dropped, plain spaces among a
/// line's closing escapes dropped (padding), trailing blank lines dropped,
/// and only the newest lines within [historyBytes].
List<String> screenLines(String text) {
  final charset = RegExp(r'\x1b[ -/]+[0-~]');
  final pad = RegExp(r'(?: |\x1b\[[0-9;:]*m)+$');
  final sgr = RegExp(r'\x1b\[[0-9;:]*m');
  final raw = text.replaceAll('\r\n', '\n').replaceAll(charset, '').split('\n');
  final kept = <String>[];
  var bytes = 0;
  for (var i = raw.length - 1; i >= 0; i--) {
    final line = raw[i].replaceFirstMapped(pad, (m) => sgr.allMatches(m[0]!).map((e) => e[0]).join());
    if (kept.isEmpty && line.replaceAll(sgr, '').isEmpty) continue;
    bytes += utf8.encode(line).length + 1;
    if (bytes > historyBytes) break;
    kept.add(line);
  }
  return kept.reversed.toList();
}

// ------------------------------------------------------------ where an agent runs

/// The key of the window a coding agent runs in, from the `term` its
/// extension reports (its environment, raw: TERM_PROGRAM, KITTY_*, TMUX,
/// TMUX_PANE, WEZTERM_*, ITERM_SESSION_ID, TERM_SESSION_ID, and `tty`).
/// tmux wins (the pane, not the terminal showing it); then the terminal
/// TERM_PROGRAM names (other terminals' variables leak into apps started
/// from them); then kitty's own variables. Null when it can't be told
/// without asking a terminal (Ghostty: [Terminals.locate]).
String? windowOfTerm(Map<String, dynamic>? term) {
  if (term == null) return null;
  String? v(String name) {
    final s = term[name];
    return s is String && s.isNotEmpty ? s : null;
  }

  final tmux = v('TMUX');
  final pane = v('TMUX_PANE');
  if (tmux != null && pane != null) {
    final socket = tmux.split(',').first.split('/').last;
    final n = pane.replaceFirst('%', '');
    if (_tmuxSocket.hasMatch(socket) && RegExp(r'^\d+$').hasMatch(n)) return 'tmux:$socket/$n';
  }
  final tty = v('tty')?.replaceFirst('/dev/', '');
  String? kitty() {
    final window = v('KITTY_WINDOW_ID');
    if (window == null) return null;
    final listen = v('KITTY_LISTEN_ON');
    final socket = listen != null
        ? listen.replaceFirst(RegExp('^unix:'), '').split('/').last
        : (v('KITTY_PID') != null ? 'kitty-${v('KITTY_PID')}' : null);
    return socket != null && RegExp(r'^kitty[\w.-]*$').hasMatch(socket) ? '$socket/$window' : null;
  }

  String? wezterm() {
    final pane = v('WEZTERM_PANE');
    final pid = RegExp(r'gui-sock-(\d+)$').firstMatch(v('WEZTERM_UNIX_SOCKET') ?? '')?[1];
    return pane != null && pid != null ? 'wezterm:$pid/$pane' : null;
  }

  String? iterm() {
    final m = RegExp(r'^(?:w\d+t\d+p\d+:)?([0-9A-Fa-f-]{36})$').firstMatch(v('ITERM_SESSION_ID') ?? '');
    return m == null ? null : 'iterm:${m[1]}';
  }

  String? terminal() => tty != null && RegExp(r'^ttys\d+$').hasMatch(tty) ? 'terminal:$tty' : null;

  return switch (v('TERM_PROGRAM')) {
    'iTerm.app' => iterm(),
    'WezTerm' => wezterm(),
    'Apple_Terminal' => terminal(),
    'ghostty' => null,
    _ => kitty() ?? wezterm() ?? iterm(),
  };
}

final _tmuxSocket = RegExp(r'^[\w.-]{1,40}$');

/// Valid tmux socket names in keys.
bool tmuxSocketName(String name) => _tmuxSocket.hasMatch(name);

// ------------------------------------------------------------ processes

/// One process as `ps` lists it.
class Proc {
  const Proc({
    required this.pid,
    required this.ppid,
    required this.pgid,
    required this.tpgid,
    required this.tty,
    required this.stat,
    required this.args,
  });
  final int pid;
  final int ppid;
  final int pgid;
  final int tpgid;

  /// `ttys012`, or empty.
  final String tty;
  final String stat;
  final String args;

  /// What runs, by name: `omp`, `claude`, `zsh`, `tmux`; a script's name
  /// for an interpreter (`node …/x.js` is x).
  String get program => programOf(args);
}

/// The program [args] (ps's `args`) runs.
String programOf(String args) {
  final words = args.trim().split(RegExp(r'\s+'));
  if (words.isEmpty || words.first.isEmpty) return '';
  String base(String w) => w.split('/').last.replaceFirst(RegExp('^-'), '');
  final first = base(words.first);
  const interpreters = {'node', 'bun', 'deno', 'python', 'python3', 'ruby', 'perl'};
  if (interpreters.contains(first)) {
    for (final w in words.skip(1)) {
      if (w.startsWith('-')) continue;
      return base(w).replaceFirst(RegExp(r'\.(m?js|ts|py|rb|pl)$'), '');
    }
  }
  return first;
}

/// A snapshot of the processes on this Mac (one `ps`), to tell a tty's
/// foreground program and whether an app runs.
class Procs {
  Procs(this.all);

  static Future<Procs> snapshot() async {
    try {
      final r = await Process.run('/bin/ps', ['-Ao', 'pid=,ppid=,pgid=,tpgid=,tty=,stat=,args=']);
      return Procs(parsePs(r.stdout as String));
    } on ProcessException {
      return Procs(const []);
    }
  }

  final List<Proc> all;

  /// The foreground program on [tty] (`ttys012` or `/dev/ttys012`): the
  /// leader of its foreground process group.
  Proc? foreground(String tty) {
    final t = tty.replaceFirst('/dev/', '');
    if (t.isEmpty) return null;
    final on = all.where((p) => p.tty == t).toList();
    return on.where((p) => p.pid == p.tpgid).firstOrNull ??
        on.where((p) => p.pgid == p.tpgid).firstOrNull ??
        on.where((p) => p.stat.contains('+')).lastOrNull;
  }

  Proc? byPid(int pid) => all.where((p) => p.pid == pid).firstOrNull;

  /// Whether a process whose command starts with [exe] runs.
  bool running(String exe) => all.any((p) => p.args.startsWith(exe));

  /// The pid of the first process whose command starts with [exe].
  int? pidOf(String exe) => all.where((p) => p.args.startsWith(exe)).firstOrNull?.pid;

  /// Working directories of [pids], in one `lsof`.
  static Future<Map<int, String>> cwds(Iterable<int> pids) async {
    final list = pids.toSet();
    if (list.isEmpty) return const {};
    try {
      final r = await Process.run('/usr/sbin/lsof', ['-a', '-d', 'cwd', '-Fpn', '-p', list.join(',')]);
      return parseLsofCwd(r.stdout as String);
    } on ProcessException {
      return const {};
    }
  }
}

/// `ps -Ao pid=,ppid=,pgid=,tpgid=,tty=,stat=,args=` as [Proc]s.
List<Proc> parsePs(String out) {
  final line = RegExp(r'^\s*(\d+)\s+(\d+)\s+(\d+)\s+(-?\d+)\s+(\S+)\s+(\S+)\s+(.*)$');
  return [
    for (final l in const LineSplitter().convert(out))
      if (line.firstMatch(l) case final m?)
        Proc(
          pid: int.parse(m[1]!),
          ppid: int.parse(m[2]!),
          pgid: int.parse(m[3]!),
          tpgid: int.parse(m[4]!),
          tty: m[5] == '?' || m[5] == '??' ? '' : m[5]!,
          stat: m[6]!,
          args: m[7]!,
        ),
  ];
}

/// `lsof -a -d cwd -Fpn -p …` as pid → directory.
Map<int, String> parseLsofCwd(String out) {
  final cwds = <int, String>{};
  int? pid;
  for (final l in const LineSplitter().convert(out)) {
    if (l.startsWith('p')) pid = int.tryParse(l.substring(1));
    if (l.startsWith('n') && pid != null) cwds[pid] = l.substring(1);
  }
  return cwds;
}

/// An executable named [name] in the usual places (a GUI app's PATH is
/// short), or in [extra]; null if none.
String? findExecutable(String name, {List<String> extra = const [], Map<String, String>? env}) {
  final path = (env ?? Platform.environment)['PATH'] ?? '';
  for (final dir in [
    ...path.split(':').where((d) => d.isNotEmpty),
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '/opt/local/bin',
    '/usr/bin',
  ]) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.path;
  }
  for (final p in extra) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

// ------------------------------------------------------------ AppleScript

/// Runs [script] with osascript on [app] (bundle id [bundle]), [args] as its
/// `on run argv`; its output without the final newline ([AppleScript.run]).
Future<String> runAppleScript(String app, String bundle, String script, [List<String> args = const []]) =>
    appleScript.run(app, bundle, script, args);

/// The terminals' [AppleScript]: what macOS answered holds for all of them.
final appleScript = AppleScript();

/// osascript, for apps macOS asks the person about before Džep may control
/// them (Privacy & Security → Automation). Until they answer, an Apple Event
/// waits in the app, which carries it out once they say yes, long after the
/// phone gave up. So an app is sent nothing before it's known to be allowed:
/// its answer is looked up first (without asking), and while there is none
/// macOS is asked once, by a helper that waits for the answer, and every
/// script throws [AutomationPending] at once instead of piling up. A script
/// that doesn't finish within [timeout] is killed.
class AppleScript {
  AppleScript({
    this.start = Process.start,
    this.timeout = const Duration(seconds: 20),
    this.stuckAfter = const Duration(seconds: 2),
    this.askFor = const Duration(minutes: 3),
  });

  /// Starts osascript; tests hand in their own.
  final Future<Process> Function(String executable, List<String> arguments) start;

  /// How long a script may run.
  final Duration timeout;

  /// A script to an app not known to be allowed (it wasn't running, so the
  /// script started it) that runs this long is checked for macOS asking.
  final Duration stuckAfter;

  /// How long the helper waits for the person's answer (macOS gives up on
  /// its question after two minutes).
  final Duration askFor;

  /// Apps macOS let Džep control, and those it's asking about, by bundle id.
  final _allowed = <String>{};
  final _asking = <String>{};

  // AEDeterminePermissionToAutomateTarget's answers.
  static const _wouldAsk = -1744;
  static const _refused = -1743;

  /// Whether Džep may send Apple Events to [bundle]: 0 yes, -1743 no,
  /// -1744 not answered yet, -600 not running; null if it can't be told.
  /// With [ask], macOS asks the person (if it hasn't) and this waits for
  /// their answer. osascript's answer counts as Džep's: macOS asks about
  /// the app that started it.
  Future<int?> consent(String bundle, {bool ask = false}) async {
    final r = await _osascript([
      '-l',
      'JavaScript',
      '-e',
      _consentScript,
      bundle,
      if (ask) 'ask' else 'look',
    ], ask ? askFor : const Duration(seconds: 5));
    return r == null || r.code != 0 ? null : int.tryParse(r.out.trim());
  }

  static const _consentScript = r'''
ObjC.import('CoreServices');
ObjC.bindFunction('AEDeterminePermissionToAutomateTarget', ['int', ['void *', 'unsigned int', 'unsigned int', 'bool']]);
function run(argv) {
  const app = $.NSAppleEventDescriptor.descriptorWithBundleIdentifier(argv[0]);
  return $.AEDeterminePermissionToAutomateTarget(app.aeDesc, 0x2a2a2a2a, 0x2a2a2a2a, argv[1] === 'ask');
}''';

  /// macOS asks about [bundle] (once at a time); a yes is remembered.
  void _ask(String bundle) {
    if (!_asking.add(bundle)) return;
    unawaited(
      consent(bundle, ask: true).then((answer) {
        _asking.remove(bundle);
        if (answer == 0) _allowed.add(bundle);
      }),
    );
  }

  Future<String> run(String app, String bundle, String script, [List<String> args = const []]) async {
    if (_asking.contains(bundle)) throw AutomationPending(app);
    var known = _allowed.contains(bundle);
    if (!known) {
      switch (await consent(bundle)) {
        case 0:
          _allowed.add(bundle);
          known = true;
        case _wouldAsk:
          _ask(bundle);
          throw AutomationPending(app);
        case _refused:
          throw AutomationDenied(app);
      }
    }
    final r = await _osascript(
      ['-e', script, ...args],
      timeout,
      stuck: known ? null : () async => await consent(bundle) == _wouldAsk,
    );
    if (r == null) throw TerminalException('$app did not answer.');
    if (r.code == _asked) {
      _ask(bundle);
      throw AutomationPending(app);
    }
    if (r.code == 0) return r.out.endsWith('\n') ? r.out.substring(0, r.out.length - 1) : r.out;
    if (r.err.contains('$_refused')) {
      _allowed.remove(bundle);
      throw AutomationDenied(app);
    }
    if (r.err.contains('$_wouldAsk')) {
      _allowed.remove(bundle);
      _ask(bundle);
      throw AutomationPending(app);
    }
    if (r.err.contains('-600') || r.err.contains('-609')) throw TerminalException("$app isn't running.");
    throw TerminalException('$app: ${r.err.replaceFirst(RegExp('^.*execution error: '), '').trim()}');
  }

  /// [_osascript]'s code for a script killed because macOS was asking.
  static const _asked = -1;

  /// osascript with [args]; null if it didn't finish within [limit]. Killed
  /// then, or once it has run [stuckAfter] and [stuck] says it waits on
  /// macOS asking (code [_asked]).
  Future<({int code, String out, String err})?> _osascript(
    List<String> args,
    Duration limit, {
    Future<bool> Function()? stuck,
  }) async {
    final Process p;
    try {
      p = await start('/usr/bin/osascript', args);
    } on ProcessException catch (e) {
      throw TerminalException('osascript: ${e.message}');
    }
    unawaited(p.stdin.close().then((_) {}, onError: (Object _) {}));
    final out = p.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    final err = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    final exited = p.exitCode.then<int?>((c) => c);
    final sw = Stopwatch()..start();
    var code = stuck == null ? null : await exited.timeout(stuckAfter, onTimeout: () => null);
    if (code == null && stuck != null && await stuck()) {
      p.kill(ProcessSignal.sigkill);
      return (code: _asked, out: '', err: '');
    }
    code ??= await exited.timeout(limit - sw.elapsed, onTimeout: () => null);
    if (code == null) {
      p.kill(ProcessSignal.sigkill);
      return null;
    }
    return (code: code, out: await out, err: await err);
  }
}

/// macOS refused Džep's Apple Events to [app] (Privacy & Security →
/// Automation).
class AutomationDenied extends TerminalException {
  AutomationDenied(this.app) : super(automationDenied(app));
  final String app;
}

String automationDenied(String app) =>
    'Džep may not control $app. Allow it in System Settings → Privacy & Security → Automation → Džep.';

/// macOS is asking the person whether Džep may control [app]: nothing goes
/// to it until they answer.
class AutomationPending extends TerminalException {
  AutomationPending(this.app) : super('macOS is asking whether Džep may control $app: answer it on the Mac.');
  final String app;
}

/// xterm's color [i] of 256 as 0xRRGGBB: 16 basic, a 6×6×6 cube, 24 greys.
int xtermRgb(int i) {
  const basic = [
    0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5, //
    0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
  ];
  if (i < 16) return basic[i];
  if (i < 232) {
    int level(int v) => v == 0 ? 0 : 55 + v * 40;
    final n = i - 16;
    return level(n ~/ 36) << 16 | level(n ~/ 6 % 6) << 8 | level(n % 6);
  }
  final g = 8 + (i - 232) * 10;
  return g << 16 | g << 8 | g;
}

/// A shell word for [s].
String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

// ------------------------------------------------------------ focus

/// The app in front (its pid and bundle id), if it can be told.
Future<({int pid, String bundle})?> frontApp() async {
  try {
    final asn = ((await Process.run('/usr/bin/lsappinfo', ['front'])).stdout as String).trim();
    if (asn.isEmpty) return null;
    final info =
        (await Process.run('/usr/bin/lsappinfo', ['info', '-only', 'pid', '-only', 'bundleid', asn])).stdout as String;
    final pid = int.tryParse(RegExp(r'"pid"\s*=\s*(\d+)').firstMatch(info)?[1] ?? '');
    final bundle = RegExp('"CFBundleIdentifier"="([^"]+)"').firstMatch(info)?[1];
    return pid == null || bundle == null ? null : (pid: pid, bundle: bundle);
  } on ProcessException {
    return null;
  }
}

/// Runs [action] (a new window, a closed one: things that can bring a
/// terminal app to the front), and gives the focus back to the app that had
/// it whenever [app] (a bundle id; null: any app) takes it, from just
/// before [action] until a second and a half after it, worked or not; by
/// pid, so a second instance of the same app (a second kitty) counts too.
/// The watching runs in an osascript of its own, which starts while
/// [action] does and answers within a few hundredths of a second, so the
/// focus is gone for about a tenth of a second.
Future<T> keepFront<T>(Future<T> Function() action, {String? app}) async {
  final before = await frontApp();
  Process? watch;
  if (before != null) {
    try {
      watch = await Process.start('/usr/bin/osascript', [
        '-l',
        'JavaScript',
        '-e',
        _keepFrontScript,
        '${before.pid}',
        app ?? '',
      ]);
      unawaited(watch.stdin.close().then((_) {}, onError: (Object _) {}));
    } on ProcessException {
      // The window still opens; only the focus may move.
    }
  }
  try {
    return await action();
  } finally {
    if (watch != null) Timer(const Duration(milliseconds: 1500), watch.kill);
  }
}

/// Activates argv[0]'s app whenever another (argv[1]'s bundle id, if any)
/// is in front; [keepFront] ends it. The run loop is turned so that
/// NSWorkspace hears about the front app changing.
const _keepFrontScript = r'''
ObjC.import('AppKit');
function run(argv) {
  const before = parseInt(argv[0]);
  const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(before);
  const ws = $.NSWorkspace.sharedWorkspace;
  const end = Date.now() + 60000;
  while (Date.now() < end) {
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.02));
    const front = ws.frontmostApplication;
    if (front.isNil()) continue;
    if (front.processIdentifier !== before && (argv[1] === '' || front.bundleIdentifier.js === argv[1])) {
      app.activateWithOptions(0);
    }
  }
}''';

/// Terminal apps by recent use, most recent first: names as
/// `lsappinfo visibleProcessList` gives them ("kitty", "iTerm2").
Future<List<String>> appsByRecency() async {
  try {
    final out = (await Process.run('/usr/bin/lsappinfo', ['visibleProcessList'])).stdout as String;
    return [for (final m in RegExp('"([^"]+)"').allMatches(out)) m[1]!.replaceAll('_', ' ')];
  } on ProcessException {
    return const [];
  }
}
