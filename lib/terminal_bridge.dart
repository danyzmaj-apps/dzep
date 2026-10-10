import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dzep/kitty.dart';
import 'package:dzep/live.dart';
import 'package:dzep/live_hub.dart';
import 'package:dzep/terminal_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The Mac side of Terminal from the iPhone (protocol: lib/live.dart): the
/// omp sessions [LiveHub] knows and kitty's windows go out on the user's
/// private topic; what the phone asks for is done here. kitty is polled only
/// while a phone has said hello lately.
class TerminalBridge {
  TerminalBridge(this._client, this._userId, this._kitty, this._hub);

  final SupabaseClient _client;
  final String _userId;
  final Kitty _kitty;
  final LiveHub _hub;

  /// A phone that hasn't said hello for this long has left.
  static const _gone = Duration(seconds: 12);

  /// How often a watched window's screen is read; the window list every
  /// third time.
  static const _tickEvery = Duration(milliseconds: 700);

  /// Live ops wait this long to go out together.
  static const _batch = Duration(milliseconds: 150);

  /// Realtime refuses big messages; a full screen is cut to this much JSON.
  static const _maxScreenJson = 90000;

  late final TerminalChannel _ch = TerminalChannel(_client, _userId, {
    'hello': _onHello,
    'sync': _onSync,
    'run': (m) => unawaited(_onRun(m)),
  }, name: 'terminal bridge');
  Process? _awake;
  Timer? _tick;
  int _ticks = 0;
  bool _polling = false;
  final _subs = <StreamSubscription<Object?>>[];

  /// Each listening phone (its `from`): what it shows, when it last said hello.
  final _phones = <String, ({String? session, String? window, DateTime seen})>{};

  List<TermWindow> _windows = const [];
  String? _kittyError;
  List<String>? _projects;
  DateTime? _projectsAt;

  /// The last state sent: without the sessions' seq and time, which change
  /// with every live op, and with them.
  String? _sentState;
  String? _sentClock;
  DateTime _sentAt = DateTime(0);
  Timer? _stateSoon;

  /// A state that differs only in seq and time (live ops already carry those)
  /// goes out at most this often; phones use it to notice lost ops.
  static const _clockEvery = Duration(seconds: 4);

  /// Per watched window: the version and lines the phones have.
  final _screens = <String, ({int v, List<String> lines})>{};
  final _fullScreen = <String>{};

  /// Ops waiting for the next batch, per session key.
  final _pendingOps = <String, ({String epoch, List<LiveOp> ops})>{};
  Timer? _flush;

  /// Phones show this session now (said so within [_gone]).
  bool watching(String sessionKey) => _phones.values.any((p) => p.session == sessionKey);

  Future<void> start() async {
    _ch.open();
    _subs
      ..add(_hub.ops.listen(_onOps))
      ..add(_hub.changes.listen((_) => _stateChanged()));
    // Away from the Mac, an idle sleep would end the bridge; the lid still
    // sleeps it. `-w`: caffeinate goes when Džep does.
    try {
      _awake = await Process.start('/usr/bin/caffeinate', ['-i', '-w', '$pid']);
    } on Object catch (e) {
      debugPrint('Džep: caffeinate: $e');
    }
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _tick?.cancel();
    _tick = null;
    _flush?.cancel();
    _stateSoon?.cancel();
    _awake?.kill();
    _awake = null;
    _phones.clear();
    await _ch.close();
  }

  void _send(String event, Map<String, dynamic> payload) =>
      unawaited(_ch.send(event, payload).then((_) {}, onError: (Object e) => debugPrint('Džep: terminal bridge: $e')));

  // ------------------------------------------------------------ phones

  void _onHello(Map<String, dynamic> p) {
    final from = p['from'] as String?;
    if (from == null) return;
    final window = p['window'] as String?;
    final before = _phones[from];
    _phones[from] = (session: p['session'] as String?, window: window, seen: DateTime.now());
    // Every hello gets the state: it's how the phone knows the Mac is there.
    _sentState = null;
    if (window != null && before?.window != window) _fullScreen.add(window);
    _tick ??= Timer.periodic(_tickEvery, (_) => unawaited(_poll()));
    unawaited(_poll(windows: true));
  }

  void _onSync(Map<String, dynamic> p) {
    final from = p['from'] as String?;
    if (from == null) return;
    final window = p['window'] as String?;
    if (window != null) {
      _fullScreen.add(window);
      unawaited(_poll());
      return;
    }
    final key = p['session'] as String?;
    final s = key == null ? null : _hub[key];
    if (s == null) return;
    // Pending ops would arrive after this answer, which covers them already.
    _flushNow();
    final log = s.log;
    final since = p['since'] as int? ?? 0;
    final reset = p['epoch'] != log.epoch || since > log.seq || since <= 0;
    final items = reset ? log.items : log.since(since);
    final chunks = chunkJson([for (final i in items) i.toJson()]);
    for (final (n, chunk) in chunks.indexed) {
      _send('items', {
        'to': from,
        'session': key,
        'epoch': log.epoch,
        'seq': log.seq,
        'reset': reset,
        'items': chunk,
        'last': n == chunks.length - 1,
        'older': log.older,
      });
    }
  }

  // ------------------------------------------------------------ live sessions

  void _onOps((LiveSession, List<LiveOp>) change) {
    final (s, ops) = change;
    if (!watching(s.key)) return;
    final pending = _pendingOps[s.key];
    if (pending != null && pending.epoch == s.log.epoch) {
      pending.ops.addAll(ops);
    } else {
      if (pending != null) _flushNow();
      _pendingOps[s.key] = (epoch: s.log.epoch, ops: [...ops]);
    }
    _flush ??= Timer(_batch, _flushNow);
  }

  void _flushNow() {
    _flush?.cancel();
    _flush = null;
    for (final MapEntry(:key, :value) in _pendingOps.entries) {
      for (final chunk in chunkJson([for (final op in value.ops) op.toJson()])) {
        _send('live', {'session': key, 'epoch': value.epoch, 'ops': chunk});
      }
    }
    _pendingOps.clear();
  }

  void _stateChanged() {
    if (_phones.isEmpty) return;
    _stateSoon ??= Timer(const Duration(milliseconds: 200), () {
      _stateSoon = null;
      _sendState();
    });
  }

  void _sendState() {
    final sessions = [for (final s in _hub.sessions) s.summary.toJson()];
    final state = {
      'windows': [for (final w in _windows) w.toJson()],
      'sessions': sessions,
      'projects': _projects,
      'home': _kitty.home,
      'error': ?_kittyError,
    };
    final key = jsonEncode({
      ...state,
      'sessions': [
        for (final s in sessions) {...s, 'seq': null, 'at': null},
      ],
    });
    final clock = jsonEncode([for (final s in sessions) (s['seq'], s['at']).toString()]);
    final now = DateTime.now();
    if (key == _sentState && (clock == _sentClock || now.difference(_sentAt) < _clockEvery)) return;
    _sentState = key;
    _sentClock = clock;
    _sentAt = now;
    _send('state', state);
  }

  // ------------------------------------------------------------ kitty

  Future<void> _poll({bool windows = false}) async {
    if (_polling) return;
    _polling = true;
    try {
      final now = DateTime.now();
      _phones.removeWhere((_, v) => now.difference(v.seen) > _gone);
      if (_phones.isEmpty) {
        _tick?.cancel();
        _tick = null;
        _screens.clear();
        return;
      }
      if (windows || _ticks++ % 3 == 0) {
        try {
          _windows = await _kitty.windows();
          _kittyError = null;
        } on KittyException catch (e) {
          _windows = const [];
          // No kitty is fine while omp sessions come in some other way.
          _kittyError = _hub.sessions.isEmpty ? e.message : null;
        }
        if (_projectsAt == null || now.difference(_projectsAt!) > const Duration(minutes: 5)) {
          _projectsAt = now;
          unawaited(
            _kitty.projects().then((p) {
              _projects = p;
              _stateChanged();
            }),
          );
        }
      }
      _sendState();
      final watched = {for (final v in _phones.values) ?v.window};
      _screens.removeWhere((k, _) => !watched.contains(k));
      for (final w in watched) {
        if (!_windows.any((x) => x.key == w)) continue;
        try {
          await _sendScreen(w);
        } on KittyException catch (e) {
          debugPrint('Džep: terminal screen $w: $e');
        }
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _sendScreen(String window) async {
    final lines = await _kitty.lines(window, history: true);
    final before = _screens[window];
    final full = before == null || _fullScreen.remove(window);
    if (!full && listEquals(before.lines, lines)) return;
    final v = (before?.v ?? 0) + 1;
    _screens[window] = (v: v, lines: lines);
    final diff = full ? null : ScreenDiff.between(before.lines, lines);
    if (diff != null) {
      _send('screen', {'window': window, 'v': v, 'diff': diff.toJson()});
      return;
    }
    var from = 0;
    var size = utf8.encode(jsonEncode(lines)).length;
    while (size > _maxScreenJson && from < lines.length - 1) {
      size -= utf8.encode(jsonEncode(lines[from])).length + 1;
      from++;
    }
    final sent = from == 0 ? lines : lines.sublist(from);
    _screens[window] = (v: v, lines: sent);
    _send('screen', {
      'window': window,
      'v': v,
      'lines': sent,
      if (before == null) 'colors': await _kitty.colors(window),
    });
  }

  // ------------------------------------------------------------ requests

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
        case 'prompt':
          await _prompt(p);
        case 'abort':
          await _hub.abort(p['session'] as String);
        case 'answer':
          await _answer(p);
        case 'older':
          await _hub.older(p['session'] as String);
        default:
          error = 'Unknown request.';
      }
    } on KittyException catch (e) {
      error = e.message;
    } on LiveException catch (e) {
      error = e.message;
    } on Object catch (e) {
      error = 'The Mac could not do that: $e';
    }
    _send('ran', {'id': id, 'error': ?error, 'window': ?window});
    unawaited(_poll(windows: p['op'] == 'launch' || p['op'] == 'close'));
  }

  /// The phone's prompt, with its images fetched from Storage (and deleted).
  Future<void> _prompt(Map<String, dynamic> p) async {
    final paths = (p['images'] as List? ?? const []).cast<String>();
    for (final path in paths) {
      if (!path.startsWith('$_userId/') || path.contains('..')) throw const LiveException('Bad image path.');
    }
    final bucket = _client.storage.from(imageBucket);
    try {
      final images = [for (final path in paths) await _image(await bucket.download(path))];
      await _hub.prompt(
        p['session'] as String,
        p['text'] as String? ?? '',
        images: images,
        followUp: p['deliver'] == 'followUp',
      );
    } finally {
      if (paths.isNotEmpty) {
        unawaited(bucket.remove(paths).then((_) {}, onError: (Object e) => debugPrint('Džep: image cleanup: $e')));
      }
    }
  }

  /// PNG and JPEG go as they are; anything else (HEIC from Photos) becomes
  /// PNG first, which every model reads.
  static Future<({String data, String mimeType})> _image(Uint8List bytes) async {
    bool starts(List<int> magic) =>
        bytes.length > magic.length && Iterable<int>.generate(magic.length).every((i) => bytes[i] == magic[i]);
    if (starts(const [0x89, 0x50, 0x4E, 0x47])) return (data: base64Encode(bytes), mimeType: 'image/png');
    if (starts(const [0xFF, 0xD8, 0xFF])) return (data: base64Encode(bytes), mimeType: 'image/jpeg');
    final dir = await Directory.systemTemp.createTemp('dzep-image');
    try {
      final input = File('${dir.path}/in')..writeAsBytesSync(bytes);
      final png = '${dir.path}/out.png';
      final conv = await Process.run('/usr/bin/sips', ['-s', 'format', 'png', input.path, '--out', png]);
      if (conv.exitCode != 0) throw const LiveException("The Mac couldn't read that image.");
      return (data: base64Encode(await File(png).readAsBytes()), mimeType: 'image/png');
    } finally {
      await dir.delete(recursive: true);
    }
  }

  /// Answers omp's question or approval with keystrokes in its kitty window,
  /// once its screen shows that the dialog is up.
  Future<void> _answer(Map<String, dynamic> p) async {
    final s = _hub[p['session'] as String];
    final ask = s?.ask;
    if (s == null || ask == null || ask.id != p['ask']) throw const LiveException('omp is no longer asking that.');
    final window = s.window;
    if (window == null) throw const LiveException('This omp runs outside kitty: answer it on the Mac.');
    final steps = answerKeys(
      ask,
      answers: [for (final a in p['answers'] as List? ?? const []) LiveAnswer.fromJson((a as Map).cast())],
      approve: p['approve'] == true,
    );
    if (!askOnScreen(ask, await _kitty.plainScreen(window))) {
      throw const LiveException("The question isn't on the Mac's screen. Open the screen to answer it there.");
    }
    for (final step in steps) {
      switch (step) {
        case Keys(:final keys):
          await _kitty.pressKeys(window, keys);
        case Typed(:final text):
          // The typed-answer editor opens on the Enter before.
          await Future<void>.delayed(const Duration(milliseconds: 250));
          await _kitty.type(window, text);
      }
    }
  }
}
