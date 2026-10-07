import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dzep/ansi.dart';
import 'package:dzep/kitty.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

// Terminal from the iPhone: the Mac's Džep relays its kitty windows over the
// private Realtime broadcast topic `terminal:<user id>` (RLS: the user's own
// topic only, supabase/migrations/*_terminal_channel.sql). Nothing is stored;
// the Mac answers only while it's awake and Džep runs with the bridge on.
//
//   iPhone → Mac  hello  {from, watch?}   every 4 s while a Terminal screen is open
//   Mac → iPhone  state  {windows, projects, home, error?}   on every hello and on changes
//   Mac → iPhone  screen {window, text, colors?}   the watched windows' text (ANSI) with the newest
//                 scrollback above it (Kitty.historyBytes), on changes;
//                 colors (kitty's palette, lib/ansi.dart) with a watch's first screen
//   iPhone → Mac  run    {id, op: send|key|launch|close|image, window?, text?, enter?, key?, cwd?, omp?, path?}
//                 image: `path` in the private `terminal` bucket (<user id>/…), uploaded by the phone
//   Mac → iPhone  ran    {id, error?, window?}

/// The private Storage bucket images from the phone pass through.
const imageBucket = 'terminal';

/// Broadcast callbacks get the payload's fields at the top level, next to
/// `event` and `type`.
RealtimeChannel _topic(SupabaseClient client, String userId) =>
    client.channel('terminal:$userId', opts: const RealtimeChannelConfig(private: true));

/// The Mac side: answers the iPhone with kitty's windows and screens, runs
/// what it asks. Polls kitty only while an iPhone has said hello lately.
class TerminalBridge {
  TerminalBridge(this._client, this._userId, this._kitty);

  final SupabaseClient _client;
  final String _userId;
  final Kitty _kitty;

  /// An iPhone that hasn't said hello for this long has left.
  static const _gone = Duration(seconds: 12);

  RealtimeChannel? _ch;
  Process? _awake;
  Timer? _tick;
  bool _polling = false;

  /// Each listening iPhone (its `from`): the window it watches, when it last said hello.
  final _phones = <String, ({String? watch, DateTime seen})>{};

  String? _sentState;
  final _sentScreens = <String, String>{};
  List<String>? _projects;
  DateTime? _projectsAt;

  Future<void> start() async {
    _ch = _topic(_client, _userId)
        .onBroadcast(event: 'hello', callback: _onHello)
        .onBroadcast(event: 'run', callback: (m) => unawaited(_onRun(m)))
        .subscribe((status, error) {
          debugPrint('Džep: terminal bridge: ${status.name}${error == null ? '' : ' $error'}');
        });
    // Away from the Mac, an idle sleep would end the bridge; the lid still
    // sleeps it. `-w`: caffeinate goes when Džep does.
    try {
      _awake = await Process.start('/usr/bin/caffeinate', ['-i', '-w', '$pid']);
    } on Object catch (e) {
      debugPrint('Džep: caffeinate: $e');
    }
  }

  Future<void> stop() async {
    _tick?.cancel();
    _tick = null;
    _awake?.kill();
    _awake = null;
    _phones.clear();
    final channel = _ch;
    _ch = null;
    if (channel != null) await _client.removeChannel(channel);
  }

  void _send(String event, Map<String, dynamic> payload) =>
      unawaited(_ch?.sendBroadcastMessage(event: event, payload: payload));

  void _onHello(Map<String, dynamic> p) {
    final from = p['from'] as String?;
    if (from == null) return;
    final watch = p['watch'] as String?;
    final before = _phones[from];
    _phones[from] = (watch: watch, seen: DateTime.now());
    // Every hello gets the state: it's how the phone knows the Mac is there.
    _sentState = null;
    // A phone that just started watching has no screen yet.
    if (watch != null && before?.watch != watch) _sentScreens.remove(watch);
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  Future<void> _onRun(Map<String, dynamic> p) async {
    final id = p['id'] as String?;
    if (id == null) return;
    String? error;
    String? window;
    try {
      switch (p['op']) {
        case 'send':
          await _kitty.send(p['window'] as String, p['text'] as String? ?? '', enter: p['enter'] != false);
        case 'key':
          await _kitty.press(p['window'] as String, p['key'] as String);
        case 'close':
          await _kitty.close(p['window'] as String);
        case 'launch':
          window = await _kitty.launch(p['cwd'] as String, omp: p['omp'] == true);
        case 'image':
          await _pasteImage(p['window'] as String, p['path'] as String);
        default:
          error = 'Unknown request.';
      }
    } on KittyException catch (e) {
      error = e.message;
    } on Object catch (e) {
      error = 'The Mac could not do that: $e';
    }
    _send('ran', {'id': id, 'error': ?error, 'window': ?window});
    unawaited(_poll());
  }

  /// Fetches the phone's upload, attaches it in [window], deletes it.
  Future<void> _pasteImage(String window, String path) async {
    if (!path.startsWith('$_userId/') || path.contains('..')) throw const KittyException('Bad image path.');
    final bucket = _client.storage.from(imageBucket);
    final file = File('${Directory.systemTemp.path}/dzep-${path.split('/').last}');
    try {
      await file.writeAsBytes(await bucket.download(path));
      await _kitty.pasteImage(window, file);
    } finally {
      if (file.existsSync()) file.deleteSync();
      unawaited(bucket.remove([path]).then((_) {}, onError: (Object e) => debugPrint('Džep: image cleanup: $e')));
    }
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final now = DateTime.now();
      _phones.removeWhere((_, v) => now.difference(v.seen) > _gone);
      if (_phones.isEmpty) {
        _tick?.cancel();
        _tick = null;
        _sentScreens.clear();
        return;
      }
      var windows = const <TermWindow>[];
      String? error;
      try {
        windows = await _kitty.windows();
      } on KittyException catch (e) {
        error = e.message;
      }
      if (_projectsAt == null || now.difference(_projectsAt!) > const Duration(minutes: 5)) {
        _projects = await _kitty.projects();
        _projectsAt = now;
      }
      final state = {
        'windows': [for (final w in windows) w.toJson()],
        'projects': _projects,
        'home': _kitty.home,
        'error': ?error,
      };
      final key = jsonEncode(state);
      if (key != _sentState) {
        _sentState = key;
        _send('state', state);
      }
      final watched = {for (final v in _phones.values) ?v.watch};
      _sentScreens.removeWhere((k, _) => !watched.contains(k));
      for (final w in watched) {
        if (!windows.any((x) => x.key == w)) continue;
        try {
          final text = await _kitty.screen(w, history: true);
          final first = !_sentScreens.containsKey(w);
          if (_sentScreens[w] == text) continue;
          _sentScreens[w] = text;
          _send('screen', {'window': w, 'text': text, if (first) 'colors': await _kitty.colors(w)});
        } on KittyException catch (e) {
          debugPrint('Džep: terminal screen $w: $e');
        }
      }
    } finally {
      _polling = false;
    }
  }
}

class TerminalException implements Exception {
  const TerminalException(this.message);
  final String message;

  @override
  String toString() => message;
}

enum TerminalLink {
  /// Joining the topic.
  connecting,

  /// Joined; no answer from the Mac yet.
  waiting,

  /// The Mac answers.
  online,

  /// The Mac stopped answering, or never did.
  offline,
}

/// The iPhone side: the Mac's kitty windows and the watched one's screen.
/// Open only while a Terminal screen is (see [attach]).
class TerminalRemote extends ChangeNotifier {
  TerminalRemote(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;
  final String _from = const Uuid().v4();

  static const _helloEvery = Duration(seconds: 4);
  static const _silent = Duration(seconds: 10);

  RealtimeChannel? _ch;
  bool _joined = false;
  Timer? _timer;
  late DateTime _openedAt;
  DateTime? _heard;
  int _users = 0;

  List<TermWindow> windows = const [];
  List<String> projects = const [];

  /// The Mac's home folder, shown as ~.
  String home = '';

  /// The Mac couldn't reach kitty (not listening, no kitten).
  String? error;

  /// The window whose screen is wanted, and the last screen of each.
  String? get watching => _watching;
  String? _watching;
  final screens = <String, String>{};

  /// Each watched window's colors, as kitty draws it.
  final colors = <String, TermColors>{};

  final _pending = <String, Completer<Map<String, dynamic>>>{};

  TerminalLink get link {
    if (!_joined) return TerminalLink.connecting;
    final now = DateTime.now();
    final heard = _heard;
    if (heard != null && now.difference(heard) < _silent) return TerminalLink.online;
    if (heard == null && now.difference(_openedAt) < _silent) return TerminalLink.waiting;
    return TerminalLink.offline;
  }

  TermWindow? window(String key) => windows.where((w) => w.key == key).firstOrNull;

  /// Screens showing the terminal call this on init and [detach] on dispose:
  /// the channel and the hellos run while at least one is up.
  void attach() {
    if (_users++ > 0) return;
    _openedAt = DateTime.now();
    _ch = _topic(_client, _userId)
        .onBroadcast(event: 'state', callback: _onState)
        .onBroadcast(event: 'screen', callback: _onScreen)
        .onBroadcast(event: 'ran', callback: _onRan)
        .subscribe((status, error) {
          debugPrint('Džep: terminal remote: ${status.name}${error == null ? '' : ' $error'}');
          _joined = status == RealtimeSubscribeStatus.subscribed;
          if (_joined) hello();
          notifyListeners();
        });
    _timer = Timer.periodic(_helloEvery, (_) {
      hello();
      // The link can turn offline without a message.
      notifyListeners();
    });
  }

  void detach() {
    if (--_users > 0) return;
    _timer?.cancel();
    _timer = null;
    _joined = false;
    _heard = null;
    final channel = _ch;
    _ch = null;
    if (channel != null) unawaited(_client.removeChannel(channel));
  }

  void hello() {
    if (!_joined) return;
    unawaited(_ch!.sendBroadcastMessage(event: 'hello', payload: {'from': _from, 'watch': ?_watching}));
  }

  void watch(String? key) {
    if (_watching == key) return;
    _watching = key;
    hello();
  }

  void _onState(Map<String, dynamic> p) {
    _heard = DateTime.now();
    windows = [for (final w in p['windows'] as List? ?? const []) TermWindow.fromJson((w as Map).cast())];
    projects = (p['projects'] as List?)?.cast<String>() ?? projects;
    home = p['home'] as String? ?? home;
    error = p['error'] as String?;
    notifyListeners();
  }

  void _onScreen(Map<String, dynamic> p) {
    _heard = DateTime.now();
    final window = p['window'] as String;
    screens[window] = p['text'] as String? ?? '';
    final c = p['colors'] as Map?;
    if (c != null) colors[window] = TermColors.fromJson(c.cast());
    notifyListeners();
  }

  void _onRan(Map<String, dynamic> p) => _pending.remove(p['id'])?.complete(p);

  Future<Map<String, dynamic>> _run(Map<String, dynamic> request, {Duration wait = const Duration(seconds: 10)}) async {
    if (link != TerminalLink.online) throw const TerminalException('The Mac is not answering.');
    final id = const Uuid().v4();
    final done = _pending[id] = Completer();
    await _ch!.sendBroadcastMessage(event: 'run', payload: {'id': id, ...request});
    final Map<String, dynamic> reply;
    try {
      reply = await done.future.timeout(wait);
    } on TimeoutException {
      _pending.remove(id);
      throw const TerminalException('The Mac did not answer.');
    }
    final error = reply['error'] as String?;
    if (error != null) throw TerminalException(error);
    return reply;
  }

  /// Types [text] into [window], then Enter.
  Future<void> send(String window, String text) => _run({'op': 'send', 'window': window, 'text': text});

  /// One of [Kitty.keys].
  Future<void> press(String window, String key) => _run({'op': 'key', 'window': window, 'key': key});

  /// Closes [window] on the Mac, with what runs in it.
  Future<void> close(String window) => _run({'op': 'close', 'window': window});

  /// Attaches [bytes] (an image file: PNG, JPEG, HEIC) to the omp prompt in
  /// [window], through the Mac's clipboard.
  Future<void> sendImage(String window, Uint8List bytes) async {
    if (link != TerminalLink.online) throw const TerminalException('The Mac is not answering.');
    final path = '$_userId/${const Uuid().v4()}';
    try {
      await _client.storage.from(imageBucket).uploadBinary(path, bytes);
    } on Object catch (e) {
      throw TerminalException("The image didn't upload: $e");
    }
    await _run({'op': 'image', 'window': window, 'path': path}, wait: const Duration(seconds: 30));
  }

  /// A new kitty window in [cwd], running omp if [omp]; its window key.
  Future<String> launch(String cwd, {required bool omp}) async =>
      (await _run({'op': 'launch', 'cwd': cwd, 'omp': omp}))['window'] as String;

  @override
  void dispose() {
    _users = 1;
    detach();
    super.dispose();
  }
}
