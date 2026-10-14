import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dzep_core/terminal.dart';

/// kitty's remote control on this Mac, spoken over its unix socket (one
/// connection per command; see https://sw.kovidgoyal.net/kitty/rc_protocol/).
/// kitty listens only with `allow_remote_control socket-only` and
/// `listen_on unix:/tmp/kitty` in kitty.conf (read at startup), which makes it
/// `/tmp/kitty-<pid>`; every unix socket named `kitty*` in /tmp that this
/// user owns counts, so several kittys work. Window keys:
/// `<socket name>/<window id>`.
class Kitty extends TerminalHost {
  Kitty({
    String? home,
    this.socketDir = '/tmp',
    this.timeout = const Duration(seconds: 5),
    this.restoreFront = true,
    int? uid,
  }) : home = home ?? Platform.environment['HOME'] ?? '',
       uid = uid ?? _getuid();

  final String home;
  final String socketDir;

  /// Whose sockets count: the user Džep runs as. /tmp is everyone's, and a
  /// socket another account put there would show its windows on the phone
  /// and get what the phone types.
  final int uid;

  static final int Function() _getuid = DynamicLibrary.process().lookupFunction<Uint32 Function(), int Function()>(
    'getuid',
  );

  /// How long one command may take, connecting included.
  final Duration timeout;

  /// Whether [launch] gives the focus back ([keepFront]); tests turn it off.
  final bool restoreFront;

  @override
  String get id => 'kitty';

  @override
  String get label => 'kitty';

  @override
  String? get appName => 'kitty';

  @override
  String? get bundleId => 'net.kovidgoyal.kitty';

  @override
  Set<TermCap> get caps => allCaps;

  static const notListening =
      "kitty isn't listening. Add `allow_remote_control socket-only` and `listen_on unix:/tmp/kitty` "
      'to kitty.conf, then restart kitty.';

  /// The lines Settings' one click appends to kitty.conf.
  static const configLines = ['allow_remote_control socket-only', 'listen_on unix:/tmp/kitty'];

  /// The protocol version we claim; kitty refuses clients newer than itself.
  static const _version = [0, 20, 0];
  static const _prefix = '\x1bP@kitty-cmd';
  static const _end = '\x1b\\';

  /// kitty.conf: `$KITTY_CONFIG_DIRECTORY`, else `$XDG_CONFIG_HOME/kitty`, else `~/.config/kitty`.
  String get configPath {
    final env = Platform.environment;
    final dir =
        env['KITTY_CONFIG_DIRECTORY'] ??
        (env['XDG_CONFIG_HOME'] != null ? '${env['XDG_CONFIG_HOME']}/kitty' : '$home/.config/kitty');
    return '$dir/kitty.conf';
  }

  /// Whether kitty.conf [text] already turns remote control on with a socket.
  static bool configured(String text) {
    bool has(String option, bool Function(String value) ok) => const LineSplitter()
        .convert(text)
        .map((l) => l.trim())
        .where((l) => l.startsWith('$option '))
        .any((l) => ok(l.substring(option.length).trim()));
    return has('allow_remote_control', (v) => v == 'socket-only' || v == 'yes' || v == 'socket') &&
        has('listen_on', (v) => v.startsWith('unix:'));
  }

  /// Appends [configLines] to kitty.conf (made if missing), after copying
  /// it to `kitty.conf.dzep-backup`; kitty reads them when it next starts.
  Future<void> configure() async {
    final file = File(configPath);
    final text = file.existsSync() ? await file.readAsString() : '';
    if (configured(text)) return;
    if (file.existsSync()) await file.copy('$configPath.dzep-backup');
    await file.parent.create(recursive: true);
    final sep = text.isEmpty || text.endsWith('\n') ? '' : '\n';
    await file.writeAsString(
      '$text$sep\n# Added by Džep: lets it reach kitty windows from your phone.\n${configLines.join('\n')}\n',
    );
  }

  bool get installed =>
      Directory('/Applications/kitty.app').existsSync() ||
      Directory('$home/Applications/kitty.app').existsSync() ||
      findExecutable('kitty') != null;

  @override
  Future<TermStatus> status(Procs procs) async {
    if (!installed) return TermStatus(id, label, TermState.missing);
    final running = procs.running('/Applications/kitty.app/') || procs.all.any((p) => p.program == 'kitty');
    if (_sockets().isNotEmpty) {
      try {
        final n = (await windows(procs)).length;
        return TermStatus(id, label, TermState.ready, note: '$n window${n == 1 ? '' : 's'}');
      } on TerminalException {
        // Only sockets left behind by a kitty that has quit.
      }
    }
    final file = File(configPath);
    if (file.existsSync() && configured(file.readAsStringSync())) {
      return TermStatus(
        id,
        label,
        running ? TermState.setup : TermState.idle,
        note: running ? 'Restart kitty to let Džep in (kitty.conf is set).' : 'Not running',
      );
    }
    return TermStatus(
      id,
      label,
      TermState.setup,
      note: 'kitty needs remote control on: one click adds it to kitty.conf.',
      fix: TermFix.kittyConfig,
    );
  }

  List<String> _sockets() {
    final dir = Directory(socketDir);
    if (!dir.existsSync()) return const [];
    final named = [
      for (final e in dir.listSync(followLinks: false))
        if (e.uri.pathSegments.last.startsWith('kitty') &&
            FileSystemEntity.typeSync(e.path, followLinks: false) == FileSystemEntityType.unixDomainSock)
          e.path,
    ];
    if (named.isEmpty) return const [];
    // `<owner uid> <path>` a line; a socket gone meanwhile has none.
    final owners = Process.runSync('/usr/bin/stat', ['-f', '%u %N', ...named]).stdout as String;
    return [
      for (final line in const LineSplitter().convert(owners))
        if (line.indexOf(' ') case final at when at > 0 && int.tryParse(line.substring(0, at)) == uid)
          line.substring(line.lastIndexOf('/') + 1),
    ]..sort();
  }

  @override
  bool owns(String key) => RegExp(r'^kitty[\w.-]*/\d+$').hasMatch(key);

  /// Runs [cmd] on the kitty behind [socket] and returns the answer's `data`
  /// (kitty sends most of it as a string, ls as JSON inside that string).
  Future<Object?> _rc(String socket, String cmd, [Map<String, Object?>? payload]) async {
    final address = InternetAddress('$socketDir/$socket', type: InternetAddressType.unix);
    final Socket s;
    try {
      s = await Socket.connect(address, 0, timeout: timeout);
    } on SocketException {
      throw const TerminalException('kitty did not answer.');
    }
    final String reply;
    try {
      s.add(utf8.encode('$_prefix${jsonEncode({'cmd': cmd, 'version': _version, 'payload': ?payload})}$_end'));
      reply = await _reply(s).timeout(timeout);
    } on TimeoutException {
      throw const TerminalException('kitty did not answer.');
    } on SocketException {
      throw const TerminalException('kitty did not answer.');
    } finally {
      s.destroy();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(reply.substring(reply.startsWith(_prefix) ? _prefix.length : 0));
    } on FormatException {
      throw const TerminalException('kitty answered gibberish.');
    }
    if (decoded is! Map) throw const TerminalException('kitty answered gibberish.');
    if (decoded['ok'] != true) {
      final error = decoded['error'] as String? ?? 'kitty refused.';
      if (error.startsWith('No matching windows')) throw const TerminalException('That window is gone.');
      throw TerminalException(error);
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
    throw const TerminalException('kitty hung up mid-answer.');
  }

  /// `<socket>/<id>` back to its parts; anything else is refused before it
  /// reaches kitty.
  (String socket, String match) _parse(String key) {
    final m = RegExp(r'^(kitty[\w.-]*)/(\d+)$').firstMatch(key);
    if (m == null || !_sockets().contains(m[1])) throw const TerminalException('That window is gone.');
    return (m[1]!, 'id:${m[2]}');
  }

  /// Every window of every listening kitty, in kitty's order.
  @override
  Future<List<TermWindow>> windows([Procs? procs]) async {
    final sockets = _sockets();
    if (sockets.isEmpty) throw const TerminalException(notListening);
    final out = <TermWindow>[];
    var answered = false;
    for (final socket in sockets) {
      final Object? data;
      try {
        data = await _rc(socket, 'ls');
      } on TerminalException {
        // A socket left behind by a kitty that has quit.
        continue;
      }
      answered = true;
      out.addAll(parseKittyLs(socket, data! as String, procs));
    }
    if (!answered) throw const TerminalException(notListening);
    return out;
  }

  @override
  Future<List<String>> lines(String key, {bool history = false}) async {
    final (socket, match) = _parse(key);
    final text =
        await _rc(socket, 'get-text', {'match': match, 'extent': history ? 'all' : 'screen', 'ansi': true}) as String?;
    return screenLines(text ?? '');
  }

  @override
  Future<String> plainScreen(String key) async {
    final (socket, match) = _parse(key);
    final text = await _rc(socket, 'get-text', {'match': match, 'extent': 'screen', 'ansi': false}) as String?;
    return (text ?? '').trimRight();
  }

  @override
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

  /// Not as a paste: omp answers a paste by also attaching whatever image is
  /// on the Mac's clipboard.
  @override
  Future<void> type(String key, String text) async {
    final (socket, match) = _parse(key);
    await _rc(socket, 'send-text', {'match': match, 'data': 'text:$text', 'bracketed_paste': 'disable'});
  }

  /// In one command, as kitty names them (`shift+tab`, `a`).
  @override
  Future<void> pressKeys(String key, List<String> names) async {
    final (socket, match) = _parse(key);
    if (names.isEmpty) return;
    await _rc(socket, 'send-key', {'match': match, 'keys': names});
  }

  /// kitty doesn't ask; the phone does, before it sends this. A kitty in
  /// the background comes to the front when one of its OS windows closes
  /// (not when a tab does): the app that was in front gets it back.
  @override
  Future<void> close(String key) async {
    final (socket, match) = _parse(key);
    Future<void> close() => _rc(socket, 'close-window', {'match': match});
    if (!restoreFront || !lastInOsWindow(await _rc(socket, 'ls') as String? ?? '[]', int.parse(match.substring(3)))) {
      return await close();
    }
    await keepFront(close, app: bundleId);
  }

  /// A new tab in the OS window of the newest window Džep opened (marked
  /// with the user variable `dzep`), or a new OS window if there's none. A
  /// kitty in the background comes to the front for a new OS window (the
  /// app that was in front gets it back), not for a tab; the tab takes no
  /// focus from a window being typed in.
  @override
  Future<String> launch(String cwd, {List<String>? command}) async {
    if (!Directory(cwd).existsSync()) throw TerminalException('No such folder: $cwd');
    final sockets = _sockets();
    if (sockets.isEmpty) throw const TerminalException(notListening);
    Future<String> open(String socket, ({int window, bool focused})? spot) async {
      final data = await _rc(socket, 'launch', {
        'args': command ?? <String>[],
        'cwd': cwd,
        'type': spot == null ? 'os-window' : 'tab',
        if (spot != null) 'match': 'window_id:${spot.window}',
        'keep_focus': spot?.focused ?? true,
        'var': ['dzep=1'],
      });
      return '$socket/${'$data'.trim()}';
    }

    TerminalException? last;
    for (final socket in sockets) {
      try {
        final spot = dzepTabSpot(await _rc(socket, 'ls') as String? ?? '[]');
        if (spot != null) return await open(socket, spot);
      } on TerminalException catch (e) {
        last = e;
      }
    }
    Future<String> window() async {
      for (final socket in sockets) {
        try {
          return await open(socket, null);
        } on TerminalException catch (e) {
          last = e;
        }
      }
      throw last ?? const TerminalException(notListening);
    }

    return restoreFront ? await keepFront(window, app: bundleId) : await window();
  }
}

/// Where in kitty's `ls` [json] a window Džep opens goes as a tab: next to
/// the newest window Džep opened before (user variable `dzep`), with
/// whether its OS window has the focus; null if there's none.
({int window, bool focused})? dzepTabSpot(String json) {
  ({int window, bool focused})? spot;
  for (final os in jsonDecode(json) as List) {
    for (final tab in (os as Map)['tabs'] as List) {
      for (final w in (tab as Map)['windows'] as List) {
        final id = (w as Map)['id'] as int;
        if ((w['user_vars'] as Map?)?.containsKey('dzep') == true && (spot == null || id > spot.window)) {
          spot = (window: id, focused: os['is_focused'] == true);
        }
      }
    }
  }
  return spot;
}

/// Whether window [id] is the last one of its OS window in kitty's `ls`
/// [json]: closing it closes the OS window.
bool lastInOsWindow(String json, int id) {
  for (final os in jsonDecode(json) as List) {
    final ids = [
      for (final tab in (os as Map)['tabs'] as List)
        for (final w in (tab as Map)['windows'] as List) (w as Map)['id'],
    ];
    if (ids.contains(id)) return ids.length == 1;
  }
  return true;
}

/// kitty's `ls` JSON (from the kitty behind [socket]) as windows; [procs]
/// gives each its tty.
List<TermWindow> parseKittyLs(String socket, String json, [Procs? procs]) => [
  for (final os in jsonDecode(json) as List)
    for (final tab in (os as Map)['tabs'] as List)
      for (final w in (tab as Map)['windows'] as List)
        () {
          final win = w as Map;
          final fg = (win['foreground_processes'] as List? ?? const []).cast<Map<dynamic, dynamic>>();
          final proc = fg.isEmpty ? null : fg.first;
          final cmd = (proc?['cmdline'] as List?)?.cast<String>() ?? (win['cmdline'] as List).cast<String>();
          return TermWindow(
            key: '$socket/${win['id']}',
            title: win['title'] as String? ?? '',
            tab: tab['title'] as String? ?? '',
            cwd: proc?['cwd'] as String? ?? win['cwd'] as String? ?? '',
            program: cmd.isEmpty ? '' : cmd.first.split('/').last.replaceFirst(RegExp('^-'), ''),
            focused: win['is_focused'] == true,
            tty: win['pid'] is int ? procs?.byPid(win['pid'] as int)?.tty ?? '' : '',
          );
        }(),
];
