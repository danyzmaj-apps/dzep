import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One kitty window, as the iPhone sees it (kitty's `ls`, minus everything
/// the phone has no business seeing, like the window's environment).
class TermWindow {
  const TermWindow({
    required this.key,
    required this.title,
    required this.tab,
    required this.cwd,
    required this.program,
    this.focused = false,
  });

  factory TermWindow.fromJson(Map<String, dynamic> j) => TermWindow(
    key: j['key'] as String,
    title: j['title'] as String? ?? '',
    tab: j['tab'] as String? ?? '',
    cwd: j['cwd'] as String? ?? '',
    program: j['program'] as String? ?? '',
    focused: j['focused'] == true,
  );

  /// `<socket name>/<window id>`: which kitty, which of its windows.
  final String key;
  final String title;

  /// The tab's title.
  final String tab;

  /// The foreground program's working directory.
  final String cwd;

  /// The foreground program's name: `omp`, `zsh`, `nvim`.
  final String program;

  /// The window kitty has focused.
  final bool focused;

  bool get isOmp => program == 'omp';

  Map<String, dynamic> toJson() => {
    'key': key,
    'title': title,
    'tab': tab,
    'cwd': cwd,
    'program': program,
    'focused': focused,
  };
}

class KittyException implements Exception {
  const KittyException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// kitty's remote control on this Mac, spoken over its unix socket (one
/// connection per command; see https://sw.kovidgoyal.net/kitty/rc_protocol/).
/// kitty listens only with `allow_remote_control socket-only` and
/// `listen_on unix:/tmp/kitty` in kitty.conf (read at startup), which makes it
/// `/tmp/kitty-<pid>`; every unix socket named `kitty*` in /tmp counts, so
/// several kittys work.
class Kitty {
  Kitty({String? home, this.socketDir = '/tmp', this.timeout = const Duration(seconds: 5)})
    : home = home ?? Platform.environment['HOME'] ?? '';

  final String home;
  final String socketDir;

  /// How long one command may take, connecting included.
  final Duration timeout;

  static const notListening =
      "kitty isn't listening. Add `allow_remote_control socket-only` and `listen_on unix:/tmp/kitty` "
      'to kitty.conf, then restart kitty.';

  /// Keys the iPhone may press, as kitty names them.
  static const keys = {'esc', 'tab', 'up', 'down', 'enter', 'ctrl+c'};

  /// The protocol version we claim; kitty refuses clients newer than itself.
  static const _version = [0, 20, 0];
  static const _prefix = '\x1bP@kitty-cmd';
  static const _end = '\x1b\\';

  List<String> _sockets() {
    final dir = Directory(socketDir);
    if (!dir.existsSync()) return const [];
    return [
      for (final e in dir.listSync(followLinks: false))
        if (e.uri.pathSegments.last.startsWith('kitty') &&
            FileSystemEntity.typeSync(e.path, followLinks: false) == FileSystemEntityType.unixDomainSock)
          e.uri.pathSegments.last,
    ]..sort();
  }

  /// Runs [cmd] on the kitty behind [socket] and returns the answer's `data`
  /// (kitty sends most of it as a string, ls as JSON inside that string).
  Future<Object?> _rc(String socket, String cmd, [Map<String, Object?>? payload]) async {
    final address = InternetAddress('$socketDir/$socket', type: InternetAddressType.unix);
    final Socket s;
    try {
      s = await Socket.connect(address, 0, timeout: timeout);
    } on SocketException {
      throw const KittyException('kitty did not answer.');
    }
    final String reply;
    try {
      s.add(utf8.encode('$_prefix${jsonEncode({'cmd': cmd, 'version': _version, 'payload': ?payload})}$_end'));
      reply = await _reply(s).timeout(timeout);
    } on TimeoutException {
      throw const KittyException('kitty did not answer.');
    } on SocketException {
      throw const KittyException('kitty did not answer.');
    } finally {
      s.destroy();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(reply.substring(reply.startsWith(_prefix) ? _prefix.length : 0));
    } on FormatException {
      throw const KittyException('kitty answered gibberish.');
    }
    if (decoded is! Map) throw const KittyException('kitty answered gibberish.');
    if (decoded['ok'] != true) {
      final error = decoded['error'] as String? ?? 'kitty refused.';
      if (error.startsWith('No matching windows')) throw const KittyException('That window is gone.');
      throw KittyException(error);
    }
    return decoded['data'];
  }

  /// Everything kitty writes back, up to (not including) the terminator.
  /// JSON escapes ESC, so the terminator can't occur inside the answer.
  static Future<String> _reply(Socket s) async {
    final bytes = BytesBuilder(copy: false);
    var prev = 0;
    await for (final chunk in s) {
      if (chunk.isEmpty) continue;
      bytes.add(chunk);
      final beforeLast = chunk.length >= 2 ? chunk[chunk.length - 2] : prev;
      if (beforeLast == 0x1b && chunk.last == 0x5c) {
        final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
        return text.substring(0, text.length - _end.length);
      }
      prev = chunk.last;
    }
    throw const KittyException('kitty hung up mid-answer.');
  }

  /// `<socket>/<id>` back to its parts; anything else is refused before it
  /// reaches kitty.
  (String socket, String match) _parse(String key) {
    final m = RegExp(r'^(kitty[\w.-]*)/(\d+)$').firstMatch(key);
    if (m == null || !_sockets().contains(m[1])) throw const KittyException('That window is gone.');
    return (m[1]!, 'id:${m[2]}');
  }

  /// Every window of every listening kitty, in kitty's order.
  Future<List<TermWindow>> windows() async {
    final sockets = _sockets();
    if (sockets.isEmpty) throw const KittyException(notListening);
    final out = <TermWindow>[];
    var answered = false;
    for (final socket in sockets) {
      final Object? data;
      try {
        data = await _rc(socket, 'ls');
      } on KittyException {
        // A socket left behind by a kitty that has quit.
        continue;
      }
      answered = true;
      for (final os in jsonDecode(data! as String) as List) {
        for (final tab in (os as Map)['tabs'] as List) {
          for (final w in (tab as Map)['windows'] as List) {
            final win = w as Map;
            final fg = (win['foreground_processes'] as List? ?? const []).cast<Map<dynamic, dynamic>>();
            final proc = fg.isEmpty ? null : fg.first;
            final cmd = (proc?['cmdline'] as List?)?.cast<String>() ?? (win['cmdline'] as List).cast<String>();
            out.add(
              TermWindow(
                key: '$socket/${win['id']}',
                title: win['title'] as String? ?? '',
                tab: tab['title'] as String? ?? '',
                cwd: proc?['cwd'] as String? ?? win['cwd'] as String? ?? '',
                program: cmd.isEmpty ? '' : cmd.first.split('/').last.replaceFirst(RegExp('^-'), ''),
                focused: win['is_focused'] == true,
              ),
            );
          }
        }
      }
    }
    if (!answered) throw const KittyException(notListening);
    return out;
  }

  /// Realtime drops or refuses messages past ~100 KB (one of 180 KB closed the
  /// socket), so scrollback keeps only its newest lines up to this many UTF-8
  /// bytes.
  static const historyBytes = 60000;

  /// What the window shows now (with [history], its scrollback above too),
  /// line by line with its colors as ANSI escapes (lib/ansi.dart reads them),
  /// without trailing padding or trailing blank lines.
  Future<List<String>> lines(String key, {bool history = false}) async {
    final (socket, match) = _parse(key);
    final text =
        await _rc(socket, 'get-text', {'match': match, 'extent': history ? 'all' : 'screen', 'ansi': true}) as String?;
    // Plain spaces at a line's end, among its closing escapes, are padding.
    final pad = RegExp(r'(?: |\x1b\[[0-9;:]*m)+$');
    final sgr = RegExp(r'\x1b\[[0-9;:]*m');
    // Newest first, stopping at the budget: scrollback can run to megabytes.
    final raw = (text ?? '').split('\n');
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

  /// What the window shows now as plain text, to check what's on screen.
  Future<String> plainScreen(String key) async {
    final (socket, match) = _parse(key);
    final text = await _rc(socket, 'get-text', {'match': match, 'extent': 'screen', 'ansi': false}) as String?;
    return (text ?? '').trimRight();
  }

  /// The window's colors: `{fg, bg, palette}` as 0xRRGGBB, palette of 256.
  Future<Map<String, Object>> colors(String key) async {
    final (socket, match) = _parse(key);
    final out = await _rc(socket, 'get-colors', {'match': match}) as String? ?? '';
    final named = <String, int>{};
    for (final line in out.split('\n')) {
      final m = RegExp(r'^(\w+)\s+#([0-9a-fA-F]{6})$').firstMatch(line.trim());
      if (m != null) named[m[1]!] = int.parse(m[2]!, radix: 16);
    }
    return {
      'fg': named['foreground'] ?? 0xDDDDDD,
      'bg': named['background'] ?? 0x000000,
      'palette': [for (var i = 0; i < 256; i++) named['color$i'] ?? 0],
    };
  }

  /// Types [text] into the window as keystrokes, then presses Enter if
  /// [enter]. Not as a paste: omp answers a paste by also attaching whatever
  /// image is on the Mac's clipboard. A line break goes in as Shift+Enter
  /// (a new line in omp's editor; a shell runs the line).
  Future<void> send(String key, String text, {required bool enter}) async {
    final (socket, match) = _parse(key);
    final newline = {
      'match': match,
      'keys': ['shift+enter'],
    };
    for (final (i, line) in text.split('\n').indexed) {
      if (i > 0) await _rc(socket, 'send-key', newline);
      if (line.isEmpty) continue;
      await _rc(socket, 'send-text', {'match': match, 'data': 'text:$line', 'bracketed_paste': 'disable'});
    }
    if (!enter) return;
    await _rc(socket, 'send-key', {
      'match': match,
      'keys': ['enter'],
    });
  }

  /// Types [text] as keystrokes, without Enter.
  Future<void> type(String key, String text) async {
    final (socket, match) = _parse(key);
    await _rc(socket, 'send-text', {'match': match, 'data': 'text:$text', 'bracketed_paste': 'disable'});
  }

  /// Presses one of [keys] (what the iPhone may press).
  Future<void> press(String key, String name) async {
    if (!keys.contains(name)) throw KittyException('Unknown key: $name');
    await pressKeys(key, [name]);
  }

  /// Presses [names] (any key kitty names, like `shift+tab` or `a`) in order,
  /// in one command.
  Future<void> pressKeys(String key, List<String> names) async {
    final (socket, match) = _parse(key);
    if (names.isEmpty) return;
    await _rc(socket, 'send-key', {'match': match, 'keys': names});
  }

  /// Closes the window and whatever runs in it (kitty doesn't ask; the
  /// iPhone does, before it sends this).
  Future<void> close(String key) async {
    final (socket, match) = _parse(key);
    await _rc(socket, 'close-window', {'match': match});
  }

  /// A new kitty OS window in [cwd] (a session of its own, like one opened by
  /// hand) running the login shell, which then starts omp if [omp]; returns
  /// the new window's key. kitty keeps its current focus.
  Future<String> launch(String cwd, {required bool omp}) async {
    if (!Directory(cwd).existsSync()) throw KittyException('No such folder: $cwd');
    final sockets = _sockets();
    if (sockets.isEmpty) throw const KittyException(notListening);
    KittyException? last;
    for (final socket in sockets) {
      final String id;
      try {
        final data = await _rc(socket, 'launch', {
          'args': <String>[],
          'cwd': cwd,
          'type': 'os-window',
          'keep_focus': true,
        });
        id = '$data'.trim();
      } on KittyException catch (e) {
        last = e;
        continue;
      }
      final key = '$socket/$id';
      // The shell reads it once it's up: the terminal holds what's typed.
      if (omp) await send(key, 'omp', enter: true);
      return key;
    }
    throw last ?? const KittyException(notListening);
  }

  /// Git repositories up to three levels under the usual code folders, for
  /// the iPhone's New session list.
  Future<List<String>> projects() async {
    final found = <String>[];
    Future<void> walk(Directory dir, int depth) async {
      final List<FileSystemEntity> entries;
      try {
        entries = await dir.list(followLinks: false).toList();
      } on FileSystemException {
        return;
      }
      if (entries.any((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty) == '.git')) {
        found.add(dir.path);
        return;
      }
      if (depth == 0) return;
      for (final e in entries) {
        final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        if (e is Directory && !name.startsWith('.') && name != 'node_modules') await walk(e, depth - 1);
      }
    }

    for (final root in ['Dev', 'Developer', 'Projects', 'code', 'src']) {
      final dir = Directory('$home/$root');
      if (dir.existsSync()) await walk(dir, 3);
    }
    return found..sort();
  }
}
