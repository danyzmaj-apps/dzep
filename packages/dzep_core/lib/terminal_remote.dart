import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dzep_core/agent.dart';
import 'package:dzep_core/ansi.dart';
import 'package:dzep_core/live.dart';
import 'package:dzep_core/live_activity.dart';
import 'package:dzep_core/terminal.dart';
import 'package:dzep_core/terminal_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

// The phone side of the terminal protocol (lib/live.dart): the Mac's coding
// sessions and terminal windows, what the phone watches, and a disk cache so
// the Terminal tab shows the last known state before the Mac answers.

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

/// A terminal window's text as the phone has it: version [v] of its [lines]
/// (ANSI), and how many lines have scrolled off the top since the phone
/// first saw it ([base]), so a view can keep its place while it scrolls.
class TermScreen {
  const TermScreen(this.v, this.lines, this.base);
  final int v;
  final List<String> lines;
  final int base;
}

/// What goes out on the topic; tests pass their own.
typedef TerminalSend = void Function(String event, Map<String, dynamic> payload);

class _Watch {
  _Watch({this.session, this.window});
  final String? session;
  final String? window;
}

/// The phone side: the Mac's coding sessions (structured, per [LiveView]) and
/// terminal windows (as screens). The channel and the hellos run between
/// [attach] and [detach]: while the app is in front.
class TerminalRemote extends ChangeNotifier {
  TerminalRemote(this._client, this._userId, this._cacheDir, {@visibleForTesting TerminalSend? send, String? from})
    : _transmit = send,
      from = from ?? const Uuid().v4() {
    _load();
  }

  final SupabaseClient _client;
  final String _userId;
  final Directory _cacheDir;
  final TerminalSend? _transmit;

  /// This phone, to the Mac.
  final String from;

  static const _helloEvery = Duration(seconds: 4);
  static const _silent = Duration(seconds: 10);

  /// A sync unanswered this long is taken as lost.
  static const _syncWait = Duration(seconds: 8);

  /// A watched session behind the state's seq this long, without live ops
  /// catching it up, syncs.
  static const _behindWait = Duration(seconds: 3);
  static const _writeEvery = Duration(seconds: 2);
  static const _keepFor = Duration(days: 14);

  late final TerminalChannel _ch = TerminalChannel(
    _client,
    _userId,
    {
      for (final event in const ['state', 'items', 'live', 'screen', 'ran']) event: (p) => _receive(event, p),
    },
    name: 'terminal remote',
    onJoined: ({required joined}) {
      // Ops may have gone by while away.
      if (joined) _watched();
      notifyListeners();
    },
  );
  Timer? _timer;
  DateTime _openedAt = DateTime.now();
  DateTime? _heard;
  int _users = 0;

  List<TermWindow> windows = const [];
  List<LiveSummary> sessions = const [];
  List<String> projects = const [];

  /// The Mac's home folder, shown as ~.
  String home = '';

  /// What a new session starts on the Mac (its setting).
  Agent agent = Agent.omp;

  /// Where a session the phone starts opens ("iTerm2", "Terminal (in tmux)");
  /// null from a Mac that doesn't say.
  String? opensIn;

  /// The Mac's terminals (installed ones, and tmux) and how each stands;
  /// empty from a Mac that doesn't say.
  List<TermStatus> terminals = const [];

  /// What the Mac can't do with its terminals, as it says it (none reachable,
  /// one not set up …).
  String? error;

  /// Phone: the sessions followed (Live Activities, Android notifications); set by the app (null
  /// in tests and wherever there are none).
  LiveActivities? activities;

  /// When the Mac last sent its state; [fromCache]: that was before this
  /// launch, read from disk.
  DateTime? stateAt;
  bool fromCache = false;

  final _views = <String, LiveView>{};

  /// Sessions with no cache file, so [view] doesn't look again.
  final _uncached = <String>{};

  /// Sessions with a sync out: when it went.
  final _syncing = <String, DateTime>{};

  /// Live ops that came while a sync was out, applied after it.
  final _held = <String, List<(String, List<LiveOp>)>>{};

  /// Watched sessions the state says are ahead: since when.
  final _behind = <String, DateTime>{};

  final _screens = <String, TermScreen>{};

  /// Each watched window's colors, as its terminal draws it.
  final colors = <String, TermColors>{};

  final _watches = <_Watch>[];
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _writes = <String, Timer>{};

  TerminalLink get link {
    // A transport handed in (tests) is always there.
    if (_transmit == null && !_ch.joined) return TerminalLink.connecting;
    final now = DateTime.now();
    final heard = _heard;
    if (heard != null && now.difference(heard) < _silent) return TerminalLink.online;
    if (heard == null && now.difference(_openedAt) < _silent) return TerminalLink.waiting;
    return TerminalLink.offline;
  }

  bool get online => link == TerminalLink.online;

  TermWindow? window(String key) => windows.where((w) => w.key == key).firstOrNull;
  LiveSummary? session(String key) => sessions.where((s) => s.key == key).firstOrNull;
  TermScreen? screen(String window) => _screens[window];

  /// The session's transcript as far as the phone has it: in memory, else
  /// from the disk cache; null if neither has it.
  LiveView? view(String key) {
    final v = _views[key];
    if (v != null || _uncached.contains(key)) return v;
    try {
      final f = _sessionFile(key);
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        return _views[key] = LiveView.fromJson(j);
      }
    } on Object catch (e) {
      debugPrint('Džep: terminal cache: $e');
    }
    _uncached.add(key);
    return null;
  }

  /// The session the phone shows, if it shows one.
  String? get watchedSession => _watches.lastOrNull?.session;

  /// The window whose screen the phone shows, if it shows one.
  String? get watchedWindow => _watches.lastOrNull?.window;

  /// Pages call these on init and the returned function on dispose; the
  /// newest one open is what the Mac hears about (one at a time), and
  /// closing it goes back to the one under it.
  VoidCallback watchSession(String key) => _watch(_Watch(session: key));
  VoidCallback watchWindow(String key) => _watch(_Watch(window: key));

  VoidCallback _watch(_Watch w) {
    _watches.add(w);
    _watched();
    return () {
      final top = identical(_watches.lastOrNull, w);
      _watches.remove(w);
      if (top) _watched();
    };
  }

  /// Tells the Mac what's watched now and catches up with it.
  void _watched() {
    hello();
    final s = watchedSession;
    if (s != null) _sync(s, force: true);
    final w = watchedWindow;
    if (w != null) _post('sync', {'from': from, 'window': w});
  }

  /// The app calls this when it comes to the front and [detach] when it
  /// leaves.
  void attach() {
    if (_users++ > 0) return;
    _openedAt = DateTime.now();
    if (_transmit != null) return;
    _ch.open();
    _timer = Timer.periodic(_helloEvery, (_) {
      hello();
      // A session left behind with no state to come still catches up.
      _checkBehind(DateTime.now());
      // The link can turn offline without a message.
      notifyListeners();
    });
  }

  void detach() {
    if (_users == 0 || --_users > 0) return;
    _timer?.cancel();
    _timer = null;
    _heard = null;
    _syncing.clear();
    _held.clear();
    _behind.clear();
    if (_transmit == null) unawaited(_ch.close());
    flush();
  }

  void hello() => _post('hello', {'from': from, 'session': ?watchedSession, 'window': ?watchedWindow});

  void _receive(String event, Map<String, dynamic> p) {
    try {
      handle(event, p);
    } on Object catch (e) {
      debugPrint('Džep: terminal remote: bad $event: $e');
    }
  }

  /// One message from the Mac.
  @visibleForTesting
  void handle(String event, Map<String, dynamic> p) {
    switch (event) {
      case 'state':
        _onState(p);
      case 'items':
        _onItems(p);
      case 'live':
        _onLive(p);
      case 'screen':
        _onScreen(p);
      case 'ran':
        _pending.remove(p['id'])?.complete(p);
    }
  }

  Future<void> _send(String event, Map<String, dynamic> payload) async {
    final t = _transmit;
    if (t != null) {
      t(event, payload);
    } else {
      await _ch.send(event, payload);
    }
  }

  void _post(String event, Map<String, dynamic> payload) =>
      unawaited(_send(event, payload).then((_) {}, onError: (Object e) => debugPrint('Džep: terminal: $e')));

  /// Asks the Mac for what [key]'s view misses. Unforced, it waits for a
  /// sync already out.
  void _sync(String key, {bool force = false}) {
    final now = DateTime.now();
    final out = _syncing[key];
    if (!force && out != null && now.difference(out) < _syncWait) return;
    _syncing[key] = now;
    _held.remove(key);
    final v = view(key);
    _post('sync', {'from': from, 'session': key, 'epoch': ?v?.epoch, 'since': v?.seq ?? 0});
  }

  bool _syncOut(String key) {
    final out = _syncing[key];
    return out != null && DateTime.now().difference(out) < _syncWait;
  }

  void _applyState(Map<String, dynamic> p) {
    windows = [for (final w in p['windows'] as List? ?? const []) TermWindow.fromJson((w as Map).cast())];
    sessions = [for (final s in p['sessions'] as List? ?? const []) LiveSummary.fromJson((s as Map).cast())];
    projects = (p['projects'] as List?)?.cast<String>() ?? projects;
    home = p['home'] as String? ?? home;
    agent = Agent.parse(p['agent']);
    opensIn = p['opensIn'] as String?;
    terminals = [for (final t in p['terminals'] as List? ?? const []) TermStatus.fromJson((t as Map).cast())];
  }

  void _onState(Map<String, dynamic> p) {
    final now = _heard = stateAt = DateTime.now();
    fromCache = false;
    _applyState(p);
    error = p['error'] as String?;
    _checkBehind(now);
    _dirty(_stateKey);
    notifyListeners();
  }

  /// Syncs the watched session when the state says the Mac has more than
  /// live ops brought (a new epoch, or a seq ahead for [_behindWait]).
  void _checkBehind(DateTime now) {
    final watched = watchedSession;
    final s = watched == null ? null : session(watched);
    if (s == null) return;
    final v = view(s.key);
    if (v == null || (s.epoch.isNotEmpty && s.epoch != v.epoch)) {
      _sync(s.key);
    } else if (s.seq > v.seq) {
      final since = _behind[s.key] ??= now;
      if (now.difference(since) >= _behindWait) {
        _behind.remove(s.key);
        _sync(s.key);
      }
    } else {
      _behind.remove(s.key);
    }
  }

  void _onItems(Map<String, dynamic> p) {
    if (p['to'] != from) return;
    _heard = DateTime.now();
    final key = p['session'] as String;
    final epoch = p['epoch'] as String;
    final last = p['last'] == true;
    final v = (view(key) ?? (_views[key] = LiveView(epoch: epoch)))
      ..catchUp(
        epoch: epoch,
        seq: p['seq'] as int,
        reset: p['reset'] == true,
        items: [for (final i in p['items'] as List? ?? const []) LiveItem.fromJson((i as Map).cast())],
        last: last,
        older: p['older'] as bool?,
      );
    if (last && v.epoch == epoch) {
      _syncing.remove(key);
      _behind.remove(key);
      for (final (e, ops) in _held.remove(key) ?? const <(String, List<LiveOp>)>[]) {
        if (!v.apply(e, ops)) {
          _sync(key);
          break;
        }
      }
    }
    _dirty(key);
    notifyListeners();
  }

  void _onLive(Map<String, dynamic> p) {
    _heard = DateTime.now();
    final key = p['session'] as String;
    final epoch = p['epoch'] as String;
    final ops = [for (final o in p['ops'] as List? ?? const []) LiveOp.fromJson((o as Map).cast())];
    final watched = key == watchedSession;
    if (watched && _syncOut(key)) {
      (_held[key] ??= []).add((epoch, ops));
      return;
    }
    // Other phones' sessions too, when this one has them at hand.
    final v = _views[key] ?? (watched ? view(key) : null);
    if (v == null) {
      if (watched) _sync(key);
      return;
    }
    if (!v.apply(epoch, ops) && watched) _sync(key);
    _dirty(key);
    notifyListeners();
  }

  void _onScreen(Map<String, dynamic> p) {
    _heard = DateTime.now();
    final window = p['window'] as String;
    final v = p['v'] as int;
    final c = p['colors'] as Map?;
    if (c != null) colors[window] = TermColors.fromJson(c.cast());
    final old = _screens[window];
    final lines = (p['lines'] as List?)?.cast<String>();
    final diff = p['diff'] is Map ? ScreenDiff.fromJson((p['diff'] as Map).cast()) : null;
    if (lines != null) {
      // How far it scrolled, if it did.
      final drop = old == null ? 0 : ScreenDiff.between(old.lines, lines)?.drop ?? 0;
      _screens[window] = TermScreen(v, lines, (old?.base ?? 0) + drop);
    } else if (diff != null) {
      final next = old != null && old.v == v - 1 ? diff.apply(old.lines) : null;
      if (next != null) {
        _screens[window] = TermScreen(v, next, old!.base + diff.drop);
      } else if (window == watchedWindow) {
        _post('sync', {'from': from, 'window': window});
      }
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ ops

  /// [request]'s answer from the Mac, sending included within [wait]. With
  /// [onLate], an answer that comes after [wait] (the Mac did it after all)
  /// still goes there, for a while.
  Future<Map<String, dynamic>> _run(
    Map<String, dynamic> request, {
    Duration wait = const Duration(seconds: 10),
    void Function(Map<String, dynamic> reply)? onLate,
  }) async {
    if (!online) throw const TerminalException('The Mac is not answering.');
    final id = const Uuid().v4();
    final done = _pending[id] = Completer();
    final Map<String, dynamic> reply;
    var later = false;
    try {
      reply = await Future(() async {
        await _send('run', {'id': id, ...request});
        return await done.future;
      }).timeout(wait);
    } on TimeoutException {
      if (onLate != null) {
        later = true;
        unawaited(
          done.future
              .timeout(_lateFor)
              .then<void>(onLate, onError: (Object _) {})
              .whenComplete(() => _pending.remove(id)),
        );
      }
      throw const TerminalException('The Mac did not answer.');
    } finally {
      if (!later) _pending.remove(id);
    }
    final error = reply['error'] as String?;
    if (error != null) throw TerminalException(error);
    return reply;
  }

  /// How long an answer that came too late is still taken.
  static const _lateFor = Duration(minutes: 2);

  /// Types [text] into [window], then Enter.
  Future<void> send(String window, String text) => _run({'op': 'send', 'window': window, 'text': text});

  /// One of [phoneKeys], where the window's terminal can press keys.
  Future<void> press(String window, String key) => _run({'op': 'key', 'window': window, 'key': key});

  /// Closes [window] on the Mac, with what runs in it.
  Future<void> close(String window) => _run({'op': 'close', 'window': window});

  /// A new terminal window in [cwd] (where [opensIn] says), running the Mac's coding [agent] if
  /// [startAgent]; its window key. Starting a terminal app can take a while;
  /// a window that opens after the phone stopped waiting is still taken as
  /// new ([_fresh]).
  Future<String> launch(String cwd, {required bool startAgent}) async {
    final reply = await _run(
      {'op': 'launch', 'cwd': cwd, 'agent': startAgent},
      wait: const Duration(seconds: 20),
      onLate: (r) {
        if (r['window'] case final String window) _fresh(window);
      },
    );
    final window = reply['window'] as String;
    _fresh(window);
    return window;
  }

  /// A window just opened under [window]'s key. A key can come back (tmux
  /// numbers panes from %0 again once its server restarts, Terminal reuses
  /// ttys): what the phone kept for it is an ended session's, and goes.
  void _fresh(String window) {
    _views.remove(window);
    _writes.remove(window)?.cancel();
    try {
      final f = _sessionFile(window);
      if (f.existsSync()) f.deleteSync();
    } on Object catch (e) {
      debugPrint('Džep: terminal cache: $e');
    }
  }

  /// Prompts [session] with [text] and [images] (image files: PNG, JPEG),
  /// which pass through Storage. While omp works the prompt steers it, or
  /// waits for the turn to end if [followUp]; Claude Code always waits.
  Future<void> prompt(String session, String text, {List<Uint8List> images = const [], bool followUp = false}) async {
    if (!online) throw const TerminalException('The Mac is not answering.');
    final bucket = _client.storage.from(imageBucket);
    final paths = <String>[];
    void forget() {
      if (paths.isEmpty) return;
      unawaited(bucket.remove(paths).then((_) {}, onError: (Object e) => debugPrint('$e')));
    }

    try {
      for (final bytes in images) {
        final path = '$_userId/${const Uuid().v4()}';
        await bucket.uploadBinary(path, bytes);
        paths.add(path);
      }
    } on Object catch (e) {
      forget();
      throw TerminalException("The image didn't upload: $e");
    }
    try {
      await _run({
        'op': 'prompt',
        'session': session,
        'text': text,
        'images': paths,
        'deliver': followUp ? 'followUp' : 'steer',
      }, wait: Duration(seconds: paths.isEmpty ? 10 : 30));
    } on TerminalException {
      // The Mac deletes them once used; unanswered, nobody would.
      forget();
      rethrow;
    }
  }

  /// Esc: stops what the agent is doing.
  Future<void> abort(String session) => _run({'op': 'abort', 'session': session});

  /// Answers [ask]: [answers] (one per question), or [approve] an approval.
  Future<void> answer(String session, LiveAsk ask, {List<LiveAnswer> answers = const [], bool approve = false}) =>
      _run({
        'op': 'answer',
        'session': session,
        'ask': ask.id,
        if (ask.isApproval) 'approve': approve else 'answers': [for (final a in answers) a.toJson()],
      });

  /// Fetches items before the oldest the Mac has; they arrive as live ops.
  Future<void> older(String session) => _run({'op': 'older', 'session': session});

  // ---------------------------------------------------------------- cache

  /// [_writes]' key for state.json (session keys are never empty).
  static const _stateKey = '';

  File get _stateFile => File('${_cacheDir.path}/state.json');
  Directory get _sessionDir => Directory('${_cacheDir.path}/sessions');
  File _sessionFile(String key) => File('${_sessionDir.path}/${sha1.convert(utf8.encode(key))}.json');

  void _load() {
    try {
      final f = _stateFile;
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        _applyState(j);
        stateAt = j['at'] is int ? DateTime.fromMillisecondsSinceEpoch(j['at'] as int) : null;
        fromCache = true;
      }
    } on Object catch (e) {
      debugPrint('Džep: terminal cache: $e');
    }
    try {
      final dir = _sessionDir;
      if (!dir.existsSync()) return;
      final now = DateTime.now();
      for (final f in dir.listSync().whereType<File>()) {
        if (now.difference(f.statSync().modified) > _keepFor) f.deleteSync();
      }
    } on Object catch (e) {
      debugPrint('Džep: terminal cache: $e');
    }
  }

  /// Writes [key]'s file (a session, or [_stateKey]) soon, at most every
  /// [_writeEvery].
  void _dirty(String key) => _writes[key] ??= Timer(_writeEvery, () {
    _writes.remove(key);
    _write(key);
  });

  /// Writes every file waiting to be.
  void flush() {
    for (final key in _writes.keys.toList()) {
      _writes.remove(key)!.cancel();
      _write(key);
    }
  }

  void _write(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final File file;
    final Map<String, dynamic> json;
    if (key == _stateKey) {
      file = _stateFile;
      json = {
        'windows': [for (final w in windows) w.toJson()],
        'sessions': [for (final s in sessions) s.toJson()],
        'projects': projects,
        'home': home,
        'agent': agent.name,
        'opensIn': ?opensIn,
        'terminals': [for (final t in terminals) t.toJson()],
        'at': stateAt?.millisecondsSinceEpoch ?? now,
      };
    } else {
      final v = _views[key];
      if (v == null) return;
      file = _sessionFile(key);
      json = {'key': key, 'at': now, ...v.toJson()};
    }
    try {
      file.parent.createSync(recursive: true);
      // Whole or not at all, should the app be killed mid-write.
      File('${file.path}.tmp')
        ..writeAsStringSync(jsonEncode(json))
        ..renameSync(file.path);
    } on Object catch (e) {
      debugPrint('Džep: terminal cache: $e');
    }
  }

  @override
  void dispose() {
    _users = 1;
    detach();
    for (final p in _pending.values) {
      if (!p.isCompleted) p.completeError(const TerminalException('Closed.'));
    }
    super.dispose();
  }
}
