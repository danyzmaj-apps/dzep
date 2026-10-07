import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One kitty window, as the iPhone sees it (`kitten @ ls`, minus everything
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

/// kitty's remote control on this Mac, through `kitten @`. kitty listens
/// only with `allow_remote_control socket-only` and `listen_on unix:/tmp/kitty`
/// in kitty.conf (read at startup), which makes it `/tmp/kitty-<pid>`; every
/// unix socket named `kitty*` in /tmp counts, so several kittys work.
class Kitty {
  Kitty({String? home, this.socketDir = '/tmp'}) : home = home ?? Platform.environment['HOME'] ?? '';

  final String home;
  final String socketDir;

  static const notListening =
      "kitty isn't listening. Add `allow_remote_control socket-only` and `listen_on unix:/tmp/kitty` "
      'to kitty.conf, then restart kitty.';

  /// Keys the iPhone may press, as kitty names them.
  static const keys = {'esc', 'tab', 'up', 'down', 'enter', 'ctrl+c'};

  /// A GUI app's PATH has no Homebrew, so look where kitty installs it.
  late final String? _kitten = [
    '/opt/homebrew/bin/kitten',
    '/usr/local/bin/kitten',
    '/Applications/kitty.app/Contents/MacOS/kitten',
    '$home/Applications/kitty.app/Contents/MacOS/kitten',
  ].where((p) => File(p).existsSync()).firstOrNull;

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

  Future<String> _rc(String socket, List<String> args, {String? stdin}) async {
    final kitten = _kitten;
    if (kitten == null) throw const KittyException("kitty's `kitten` isn't installed on this Mac.");
    final p = await Process.start(kitten, ['@', '--to', 'unix:$socketDir/$socket', ...args]);
    if (stdin != null) p.stdin.write(stdin);
    await p.stdin.close();
    const decoder = Utf8Decoder(allowMalformed: true);
    final out = p.stdout.transform(decoder).join();
    final err = p.stderr.transform(decoder).join();
    final code = await p.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        p.kill();
        return -1;
      },
    );
    if (code != 0) {
      final msg = (await err).trim().replaceFirst(RegExp('^Error: '), '');
      throw KittyException(msg.isEmpty ? 'kitty did not answer.' : msg);
    }
    return await out;
  }

  /// `<socket>/<id>` back to its parts; anything else is refused before it
  /// reaches a command line.
  (String socket, int id) _parse(String key) {
    final m = RegExp(r'^(kitty[\w.-]*)/(\d+)$').firstMatch(key);
    if (m == null || !_sockets().contains(m[1])) throw const KittyException('That window is gone.');
    return (m[1]!, int.parse(m[2]!));
  }

  /// [_parse] for typing: kitty's send-text and send-key succeed quietly
  /// when no window matches, so ask first.
  Future<(String socket, int id)> _live(String key) async {
    final (socket, id) = _parse(key);
    try {
      await _rc(socket, ['ls', '--match', 'id:$id']);
    } on KittyException {
      throw const KittyException('That window is gone.');
    }
    return (socket, id);
  }

  /// Every window of every listening kitty, in kitty's order.
  Future<List<TermWindow>> windows() async {
    final sockets = _sockets();
    if (sockets.isEmpty) throw const KittyException(notListening);
    final out = <TermWindow>[];
    var answered = false;
    for (final socket in sockets) {
      final String json;
      try {
        json = await _rc(socket, ['ls']);
      } on KittyException {
        // A socket left behind by a kitty that has quit.
        continue;
      }
      answered = true;
      for (final os in jsonDecode(json) as List) {
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

  /// What the window shows now, with its colors as ANSI escapes (lib/ansi.dart
  /// reads them), without trailing blanks.
  Future<String> screen(String key) async {
    final (socket, id) = _parse(key);
    final text = await _rc(socket, ['get-text', '--match', 'id:$id', '--extent', 'screen', '--ansi']);
    // Plain spaces at a line's end, among its closing escapes, are padding.
    final pad = RegExp(r'(?: |\x1b\[[0-9;:]*m)+$');
    final sgr = RegExp(r'\x1b\[[0-9;:]*m');
    return text
        .split('\n')
        .map((l) => l.replaceFirstMapped(pad, (m) => sgr.allMatches(m[0]!).map((e) => e[0]).join()))
        .join('\n')
        .trimRight();
  }

  /// The window's colors: `{fg, bg, palette}` as 0xRRGGBB, palette of 256.
  Future<Map<String, Object>> colors(String key) async {
    final (socket, id) = _parse(key);
    final out = await _rc(socket, ['get-colors', '--match', 'id:$id']);
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
    final (socket, id) = await _live(key);
    for (final (i, line) in text.split('\n').indexed) {
      if (i > 0) await _rc(socket, ['send-key', '--match', 'id:$id', 'shift+enter']);
      if (line.isEmpty) continue;
      await _rc(socket, ['send-text', '--match', 'id:$id', '--stdin', '--bracketed-paste', 'disable'], stdin: line);
    }
    if (enter) await press(key, 'enter');
  }

  Future<void> press(String key, String name) async {
    if (!keys.contains(name)) throw KittyException('Unknown key: $name');
    final (socket, id) = await _live(key);
    await _rc(socket, ['send-key', '--match', 'id:$id', name]);
  }

  /// Closes the window and whatever runs in it (kitty doesn't ask; the
  /// iPhone does, before it sends this).
  Future<void> close(String key) async {
    final (socket, id) = await _live(key);
    await _rc(socket, ['close-window', '--match', 'id:$id']);
  }

  /// Attaches [image] (any format macOS reads) to the omp prompt in the
  /// window: it goes on the Mac's clipboard as PNG, then Ctrl+V, which omp
  /// answers by attaching the clipboard's image. Replaces the clipboard.
  Future<void> pasteImage(String key, File image) async {
    final (socket, id) = await _live(key);
    final png = '${image.path}.png';
    try {
      final conv = await Process.run('/usr/bin/sips', ['-s', 'format', 'png', image.path, '--out', png]);
      if (conv.exitCode != 0) throw const KittyException("The Mac couldn't read that image.");
      final set = await Process.run('/usr/bin/osascript', [
        '-e',
        'set the clipboard to (read (POSIX file "$png") as «class PNGf»)',
      ]);
      if (set.exitCode != 0) throw KittyException("The image didn't go on the Mac's clipboard: ${set.stderr}");
      await _rc(socket, ['send-key', '--match', 'id:$id', 'ctrl+v']);
    } finally {
      final f = File(png);
      if (f.existsSync()) f.deleteSync();
    }
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
        id = (await _rc(socket, ['launch', '--type', 'os-window', '--keep-focus', '--cwd', cwd])).trim();
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
