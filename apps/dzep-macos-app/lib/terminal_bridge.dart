import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dzep_core/agent.dart';
import 'package:dzep_core/live.dart';
import 'package:dzep_core/live_activity.dart';
import 'package:dzep_core/terminal.dart';
import 'package:dzep_core/terminal_channel.dart';
import 'package:dzep_core/terminals.dart';
import 'package:dzep_macos/live_hub.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The Mac side of Terminal from the phone (protocol: packages/dzep_core/lib/live.dart): the
/// coding sessions [LiveHub] knows and the terminals' windows
/// (packages/dzep_core/lib/terminals.dart) go out on the user's private
/// topic; what the phone asks for is done here, where the window's
/// terminal can do it. The terminals are polled only while a phone has said
/// hello lately.
class TerminalBridge {
  TerminalBridge(this._client, this._userId, this._terms, this._hub, this._agent, this._app, this._roots);

  final SupabaseClient _client;
  final String _userId;
  final Terminals _terms;
  final LiveHub _hub;

  /// The agent a new session from the phone starts (the Mac's setting).
  final Agent Function() _agent;

  /// The terminal app it opens in: an app's id or `auto` (the Mac's setting).
  final String Function() _app;

  /// The Mac's Project folders setting.
  final List<String> Function() _roots;

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
  String? _termError;
  List<String>? _projects;
  DateTime? _projectsAt;
  List<String> _projectsRoots = const [];

  /// The installed terminals and how they stand, and where a new session
  /// opens (its label), as of [_statusesAt].
  List<TermStatus> _statuses = const [];
  String? _opensIn;
  DateTime? _statusesAt;

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

  /// Asks (their ids) whose screen is being followed: plan reviews, and
  /// Claude Code's approvals, which its plugin can't see answered.
  final _followed = <String>{};
  bool _stopped = false;

  /// How often a followed ask's screen is read: often while it opens, then
  /// now and then to follow its cursor and notice it go.
  static const _askSoon = Duration(milliseconds: 500);
  static const _askOpening = 6;
  static const _askEvery = Duration(seconds: 3);

  /// Sessions whose screen is followed for pickers (/resume, /model …) after
  /// a slash command from the phone, and the pickers' ids so far.
  final _menus = <String, _MenuWatch>{};
  int _menuIds = 0;

  /// A picker's screen is read this often for [_menuOpening] after the
  /// command or an answer, then [_menuEvery], until nothing changed for
  /// [_menuIdle].
  static const _menuSoon = Duration(milliseconds: 400);
  static const _menuOpening = Duration(seconds: 3);
  static const _menuEvery = Duration(milliseconds: 1500);
  static const _menuIdle = Duration(minutes: 2);

  /// Each session's Live Activity state as last seen (packages/dzep_core/lib/live_activity.dart)
  /// and as last pushed; a change goes out once it has held for
  /// [_activityWait], so a quick busy flicker between turns stays home.
  final _activitySeen = <String, ActivityStatus>{};
  final _activitySent = <String, ActivityStatus>{};
  final _activitySoon = <String, Timer>{};
  static const _activityWait = Duration(seconds: 2);

  /// Phones show this session now (said so within [_gone]).
  bool watching(String sessionKey) => _phones.values.any((p) => p.session == sessionKey);

  Future<void> start() async {
    _stopped = false;
    _ch.open();
    _subs
      ..add(_hub.ops.listen(_onOps))
      ..add(
        _hub.changes.listen((_) {
          _stateChanged();
          _activitiesChanged();
        }),
      )
      ..add(
        _hub.events.listen((e) {
          if (e is LiveAsked && (e.ask.isPlan || (e.ask.isApproval && e.session.agent == Agent.claude))) {
            unawaited(_followAsk(e.session.key, e.ask.id));
          }
        }),
      );
    // Away from the Mac, an idle sleep would end the bridge; the lid still
    // sleeps it. `-w`: caffeinate goes when Džep does.
    try {
      _awake = await Process.start('/usr/bin/caffeinate', ['-i', '-w', '$pid']);
    } on Object catch (e) {
      debugPrint('Džep: caffeinate: $e');
    }
  }

  Future<void> stop() async {
    _stopped = true;
    for (final w in _menus.values) {
      w.wake();
    }
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _tick?.cancel();
    _tick = null;
    _flush?.cancel();
    _stateSoon?.cancel();
    for (final t in _activitySoon.values) {
      t.cancel();
    }
    _activitySoon.clear();
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

  // ------------------------------------------------------------ Live Activities

  /// A session started or stopped working, asks or stopped asking, or went:
  /// its Live Activity on the phone hears about it through the server
  /// (functions/push {action: activity}), which does nothing for a session
  /// no phone follows. A session seen for the first time pushes nothing:
  /// no phone can follow it yet.
  void _activitiesChanged() {
    for (final s in _hub.sessions) {
      final status = activityStatus(busy: s.busy, ask: s.ask);
      final seen = _activitySeen[s.key];
      _activitySeen[s.key] = status;
      if (seen == null) {
        _activitySent[s.key] ??= status;
      } else if (seen != status) {
        _activitySoon[s.key]?.cancel();
        _activitySoon[s.key] = Timer(_activityWait, () => _pushActivity(s.key));
      }
    }
    for (final key in _activitySeen.keys.where((k) => _hub[k] == null).toList()) {
      if (_activitySeen[key]!.state == ActivityState.ended) continue;
      _activitySeen[key] = (state: ActivityState.ended, kind: null);
      _activitySoon[key]?.cancel();
      _activitySoon[key] = Timer(_activityWait, () => _pushActivity(key));
    }
  }

  void _pushActivity(String key) {
    _activitySoon.remove(key);
    final status = _activitySeen[key];
    if (status == null || status == _activitySent[key]) return;
    _activitySent[key] = status;
    if (status.state == ActivityState.ended) {
      _activitySeen.remove(key);
      _activitySent.remove(key);
    }
    unawaited(
      _client.functions
          .invoke('push', body: {'action': 'activity', 'session': key, ...activityJson(status)})
          .then((_) {}, onError: (Object e) => debugPrint('Džep: Live Activity push: $e')),
    );
  }

  void _sendState() {
    final sessions = [for (final s in _hub.sessions) s.summary.toJson()];
    final state = {
      'windows': [for (final w in _windows) w.toJson()],
      'sessions': sessions,
      'projects': _projects,
      'roots': _roots(),
      'home': _terms.home,
      'agent': _agent().name,
      'opensIn': ?_opensIn,
      'terminals': [for (final s in phoneTerminals(_statuses)) s.toJson()],
      'error': ?_termError,
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

  // ------------------------------------------------------------ terminals

  /// How often Settings-like statuses are read again while phones listen.
  static const _statusEvery = Duration(seconds: 30);

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
        _windows = await _terms.windows();
        if (windows || _statusesAt == null || now.difference(_statusesAt!) > _statusEvery) {
          _statusesAt = now;
          _statuses = await _terms.statuses();
          _opensIn = _terms.describe(await _terms.opensIn(_app()));
        }
        _termError = terminalsError(_statuses, nothingShown: _windows.isEmpty && _hub.sessions.isEmpty);
        final roots = _roots();
        if (_projectsAt == null ||
            !listEquals(roots, _projectsRoots) ||
            now.difference(_projectsAt!) > const Duration(minutes: 5)) {
          _projectsAt = now;
          _projectsRoots = roots;
          unawaited(
            _terms.projects(roots).then((p) {
              // A scan of folders since changed (a slow one, of ~ say) is stale.
              if (!listEquals(roots, _projectsRoots)) return;
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
        final shown = _windows.where((x) => x.key == w).firstOrNull;
        if (shown == null || !shown.can(TermCap.read)) continue;
        try {
          await _sendScreen(w);
        } on TerminalException catch (e) {
          debugPrint('Džep: terminal screen $w: $e');
        }
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _sendScreen(String window) async {
    final lines = await _terms.lines(window, history: true);
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
      if (before == null) 'colors': ?await _terms.colors(window),
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
          await _terms.send(p['window'] as String, p['text'] as String? ?? '', enter: p['enter'] != false);
        case 'key':
          final pressed = p['window'] as String;
          await _terms.press(pressed, p['key'] as String);
          // Esc on a picker, say: see it go soon.
          for (final s in _hub.sessions) {
            if (s.window == pressed) _menus[s.key]?.arm();
          }
        case 'close':
          await _terms.close(p['window'] as String);
        case 'launch':
          // An older phone says `omp` for "start the coding agent".
          final start = p['agent'] == true || p['omp'] == true;
          final host = await _terms.opensIn(_app());
          window = await _terms.launch(p['cwd'] as String, host: host, agent: start ? _agent() : null);
        case 'create':
          window = await _terms.launchNewProject(
            p['root'] as String,
            p['name'] as String? ?? '',
            roots: _roots(),
            host: await _terms.opensIn(_app()),
            agent: p['agent'] == true ? _agent() : null,
          );
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
    } on TerminalException catch (e) {
      error = e.message;
    } on LiveException catch (e) {
      error = e.message;
    } on Object catch (e) {
      error = 'The Mac could not do that: $e';
    }
    _send('ran', {'id': id, 'error': ?error, 'window': ?window});
    unawaited(_poll(windows: p['op'] == 'launch' || p['op'] == 'create' || p['op'] == 'close'));
  }

  /// The phone's prompt, with its images fetched from Storage (and deleted).
  Future<void> _prompt(Map<String, dynamic> p) async {
    // The agent's own commands (/resume, /model …) are read by its editor,
    // not the model: type them into its window like the person would, and
    // follow the pickers they open.
    final text = (p['text'] as String? ?? '').trim();
    final key = p['session'] as String;
    final window = _hub[key]?.window;
    if (text.startsWith('/') && (p['images'] as List? ?? const []).isEmpty) {
      // Sent as a prompt instead, the agent would take it for chat.
      if (cantCommand(_terms, window) case final why?) throw LiveException(why);
      await _terms.send(window!, text, enter: true);
      unawaited(_followMenus(key));
      return;
    }
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
  static Future<({Uint8List bytes, String mimeType})> _image(Uint8List bytes) async {
    bool starts(List<int> magic) =>
        bytes.length > magic.length && Iterable<int>.generate(magic.length).every((i) => bytes[i] == magic[i]);
    if (starts(const [0x89, 0x50, 0x4E, 0x47])) return (bytes: bytes, mimeType: 'image/png');
    if (starts(const [0xFF, 0xD8, 0xFF])) return (bytes: bytes, mimeType: 'image/jpeg');
    final dir = await Directory.systemTemp.createTemp('dzep-image');
    try {
      final input = File('${dir.path}/in')..writeAsBytesSync(bytes);
      final png = '${dir.path}/out.png';
      final conv = await Process.run('/usr/bin/sips', ['-s', 'format', 'png', input.path, '--out', png]);
      if (conv.exitCode != 0) throw const LiveException("The Mac couldn't read that image.");
      return (bytes: await File(png).readAsBytes(), mimeType: 'image/png');
    } finally {
      await dir.delete(recursive: true);
    }
  }

  /// Follows on its screen an ask whose end the agent's extension can't
  /// see: a plan review (dismissed with Esc on the Mac), or Claude Code's
  /// approval (its plugin hears only once the tool has run). A plan's
  /// options are published once it has rendered, and again when its cursor
  /// moves. An ask gone from the screen twice running goes from the hub too.
  Future<void> _followAsk(String key, String id) async {
    if (!_followed.add(id)) return;
    try {
      var misses = 0;
      for (var n = 0; !_stopped; n++) {
        final opening = n < _askOpening;
        await Future<void>.delayed(opening ? _askSoon : _askEvery);
        final s = _hub[key];
        final ask = s?.ask;
        final window = s?.window;
        if (s == null || ask == null || ask.id != id || window == null || !_terms.can(window, TermCap.read)) return;
        final String screen;
        try {
          screen = await _terms.plainScreen(window);
        } on TerminalException catch (e) {
          debugPrint('Džep: ask on screen $window: $e');
          if (opening) continue;
          return;
        }
        final review = ask.isPlan ? parsePlanReview(screen, agent: s.agent) : null;
        if (review != null) {
          misses = 0;
          if (!listEquals(review.options, ask.options) || review.current != ask.selected) {
            _hub.updateAsk(
              key,
              id,
              LiveAsk.plan(id, title: ask.title, options: review.options, selected: review.current),
            );
          }
        } else if (askOnScreen(ask, screen, agent: s.agent)) {
          misses = 0;
        } else if (!opening && ++misses >= 2) {
          _hub.updateAsk(key, id, null);
          return;
        }
      }
    } finally {
      _followed.remove(id);
    }
  }

  /// Picks the plan review option [p] names, once the screen still lists it
  /// there. Claude Code's rows go by their number. omp's cursor moves from
  /// where it is now (someone may have moved it on the Mac) down or up to
  /// it, and Enter goes once the screen shows the cursor there: ↓/↑ skip an
  /// option omp has disabled, which plain text doesn't show, and a cursor
  /// that won't land on the option means omp won't take it.
  Future<void> _answerPlan(String window, LiveAsk ask, Agent agent, Map<String, dynamic> p) async {
    final answers = [for (final a in p['answers'] as List? ?? const []) LiveAnswer.fromJson((a as Map).cast())];
    final pick = answers.length == 1 && answers.single.picks.length == 1 ? answers.single.picks.single : -1;
    if (pick < 0) throw const LiveException('Pick one option.');
    for (var tries = 0; tries < 4; tries++) {
      final review = parsePlanReview(await _terms.plainScreen(window), agent: agent);
      if (review == null) {
        throw const LiveException(
          "The plan review isn't ready on the Mac's screen. Open the screen to answer it there.",
        );
      }
      if (pick >= review.options.length || (pick < ask.options.length && review.options[pick] != ask.options[pick])) {
        throw const LiveException('The plan review on the Mac has changed. Open the screen to answer it there.');
      }
      if (agent == Agent.claude) {
        await _terms.pressKeys(window, [claudeRowKey(pick)]);
        return;
      }
      if (review.current == pick) {
        await _terms.pressKeys(window, const ['enter']);
        return;
      }
      await _terms.pressKeys(window, menuKeys(review.current, pick, enter: false));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw const LiveException("omp won't move to that option. Open the screen to answer it there.");
  }

  /// Follows session [key]'s screen for the pickers a slash command opens
  /// (/resume, /model, /tree …) and publishes each as a menu ask: its rows,
  /// cursor and search as they change, a new ask for each new picker (one
  /// can open another), none once it has gone two reads running. Read often
  /// for a while after the command or an answer, then less; it stops when
  /// no picker is up after that while, or nothing changed for [_menuIdle].
  /// The agent's own asks come first: a picker never replaces one. Again for a
  /// session already followed just reads sooner.
  Future<void> _followMenus(String key) async {
    final known = _menus[key];
    if (known != null) {
      known.arm();
      return;
    }
    final w = _menus[key] = _MenuWatch();
    String? published;
    try {
      var misses = 0;
      while (!_stopped) {
        var now = DateTime.now();
        if (now.difference(w.changed) > _menuIdle) break;
        final opening = now.difference(w.armed) < _menuOpening;
        if (published == null && !opening) break;
        await w.sleep(opening ? _menuSoon : _menuEvery);
        final s = _hub[key];
        final window = s?.window;
        if (s == null || window == null || _stopped || !_terms.can(window, TermCap.read)) break;
        final current = s.ask;
        // The agent asks something itself, or the picker's ask went (a new session's hello).
        if (current != null && current.id != published) break;
        if (current == null && published != null) published = null;
        final String screen;
        try {
          screen = await _terms.plainScreen(window);
        } on TerminalException catch (e) {
          debugPrint('Džep: picker $window: $e');
          break;
        }
        now = DateTime.now();
        final menu = parseMenu(screen);
        if (menu == null) {
          if (published != null && ++misses >= 2) {
            _hub.updateAsk(key, published, null);
            published = null;
            w.query = '';
          }
          continue;
        }
        misses = 0;
        final same = current != null && current.title == menu.title;
        final ask = LiveAsk.menu(
          same ? current.id : 'menu-${++_menuIds}',
          title: menu.title,
          items: menu.items,
          selected: menu.current,
          filter: menu.filter,
        );
        if (same && jsonEncode(ask.toJson()) == jsonEncode(current.toJson())) continue;
        if (!_hub.updateAsk(key, published, ask)) break;
        if (!same) w.query = '';
        published = ask.id;
        w.changed = now;
      }
    } finally {
      if (identical(_menus[key], w)) _menus.remove(key);
      if (published != null) _hub.updateAsk(key, published, null);
    }
  }

  /// Answers a picker: a pick moves its cursor from where it is now to the
  /// row (once that row still reads the same) and presses Enter; typed text
  /// becomes its search, by typing what's new and erasing only what was
  /// typed from the phone before (Backspace on an empty search can mean
  /// something else: /resume deletes the session). The picker is then read
  /// again soon, as is whatever it opens next.
  Future<void> _answerMenu(String key, String window, LiveAsk ask, Map<String, dynamic> p) async {
    final answers = [for (final a in p['answers'] as List? ?? const []) LiveAnswer.fromJson((a as Map).cast())];
    final answer = answers.length == 1 ? answers.single : null;
    final w = _menus[key];
    final menu = parseMenu(await _terms.plainScreen(window));
    if (w == null || menu == null || menu.title != ask.title) {
      throw const LiveException("The menu isn't on the Mac's screen anymore. Open the screen to see what is.");
    }
    final query = answer?.custom;
    if (query != null && answer!.picks.isEmpty) {
      if (!menu.filter) throw const LiveException("This menu can't be searched.");
      var same = 0;
      while (same < query.length && same < w.query.length && query[same] == w.query[same]) {
        same++;
      }
      await _terms.pressKeys(window, [for (var k = same; k < w.query.length; k++) 'backspace']);
      if (same < query.length) await _terms.type(window, query.substring(same));
      w
        ..query = query
        ..arm();
      return;
    }
    final pick = answer != null && answer.picks.length == 1 ? answer.picks.single : -1;
    if (pick < 0 || pick >= ask.items.length) throw const LiveException('Pick one item.');
    var shown = menu;
    for (var tries = 0; tries < 4; tries++) {
      if (pick >= shown.items.length || shown.items[pick].label != ask.items[pick].label) {
        throw const LiveException('The menu on the Mac has changed. Pick again.');
      }
      if (shown.current == pick) {
        await _terms.pressKeys(window, const ['enter']);
        w
          ..query = ''
          ..arm();
        return;
      }
      await _terms.pressKeys(window, menuKeys(shown.current, pick, enter: false));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final again = parseMenu(await _terms.plainScreen(window));
      if (again == null || again.title != ask.title) {
        throw const LiveException("The menu isn't on the Mac's screen anymore. Open the screen to see what is.");
      }
      shown = again;
    }
    throw const LiveException("The agent won't move to that item. Open the screen to pick it there.");
  }

  /// Answers the agent's question, approval, plan review or a picker with
  /// keystrokes in its terminal window, once its screen shows that it is
  /// up: only where the terminal can both show its screen and press keys.
  Future<void> _answer(Map<String, dynamic> p) async {
    final s = _hub[p['session'] as String];
    final ask = s?.ask;
    if (s == null || ask == null || ask.id != p['ask']) throw const LiveException('That is no longer being asked.');
    final window = s.window;
    if (window == null) {
      throw const LiveException("Džep can't tell which terminal window this session runs in: answer it on the Mac.");
    }
    if (cantAnswer(_terms, window) case final why?) throw LiveException(why);
    if (ask.isPlan) return await _answerPlan(window, ask, s.agent, p);
    if (ask.isMenu) return await _answerMenu(s.key, window, ask, p);
    final steps = answerKeys(
      ask,
      answers: [for (final a in p['answers'] as List? ?? const []) LiveAnswer.fromJson((a as Map).cast())],
      approve: p['approve'] == true,
      agent: s.agent,
    );
    if (!askOnScreen(ask, await _terms.plainScreen(window), agent: s.agent)) {
      throw const LiveException("The question isn't on the Mac's screen. Open the screen to answer it there.");
    }
    for (final step in steps) {
      switch (step) {
        case Keys(:final keys):
          await _terms.pressKeys(window, keys);
        case Typed(:final text):
          await _terms.type(window, text);
        case Settle():
          await Future<void>.delayed(const Duration(milliseconds: 450));
      }
    }
    await _answered(s, window, ask);
  }

  /// Waits for the agent to take the answer: its extension drops the ask
  /// (omp's when the tool ends, Claude Code's once the tool has run), or the
  /// dialog leaves the screen, which comes first for an approved long
  /// command; the ask goes then. omp's dialog still waiting on its Submit
  /// tab gets one more Enter: keys that came while it redrew were dropped.
  Future<void> _answered(LiveSession s, String window, LiveAsk ask) async {
    bool pending() => _hub[s.key]?.ask?.id == ask.id;
    var nudged = false;
    var gone = 0;
    for (var i = 0; i < 16 && pending(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (i < 2 || !pending()) continue;
      final screen = await _terms.plainScreen(window);
      if (!askOnScreen(ask, screen, agent: s.agent)) {
        if (++gone < 2) continue;
        _hub.updateAsk(s.key, ask.id, null);
        return;
      }
      gone = 0;
      if (i >= 7 && !nudged && s.agent == Agent.omp && _submitTab.hasMatch(screen)) {
        nudged = true;
        await _terms.pressKeys(window, const ['enter']);
      }
    }
    if (pending()) {
      throw LiveException(
        "${s.agent.label} hasn't taken the answer yet. Open the screen to check what it's waiting for.",
      );
    }
  }

  /// omp's ask dialog on its last tab, the answers listed above Submit.
  static final _submitTab = RegExp(r'Review answers[\s\S]*❯\s*Submit');
}

/// The terminals the phone hears about: the installed ones, and tmux
/// either way (its note says how to get it).
List<TermStatus> phoneTerminals(List<TermStatus> statuses) => [
  for (final s in statuses)
    if (s.state != TermState.missing || s.id == 'tmux') s,
];

/// The phone's error line: only when [nothingShown] (no window, no session)
/// and no terminal is usable, what the first one needing setup says.
String? terminalsError(List<TermStatus> statuses, {required bool nothingShown}) =>
    nothingShown && !statuses.any((s) => s.usable)
    ? statuses.where((s) => s.state == TermState.setup).map((s) => s.note).firstOrNull
    : null;

/// Why an agent's ask in [window] can't be answered from the phone (null:
/// it can): answering reads the screen and presses keys.
String? cantAnswer(Terminals terms, String window) {
  final read = terms.can(window, TermCap.read);
  if (read && terms.can(window, TermCap.keys)) return null;
  final label = terms.hostOf(window)?.label ?? 'This terminal';
  return "$label can't ${read ? 'press keys' : 'show its screen'}, so answer this on the Mac. "
      '${terms.tmux.installed ? 'Sessions you start from the phone run in tmux there, which can.' : 'With tmux (brew install tmux), sessions you start from the phone can.'}';
}

/// Why a slash command for the session in [window] can't be run from the
/// phone (null: it can): the agent's editor reads commands, so they're typed
/// into its terminal window.
String? cantCommand(Terminals terms, String? window) {
  if (window == null) {
    return "Slash commands are typed into the agent's terminal window, and Džep can't reach this one: it isn't in "
        'kitty, tmux, WezTerm, iTerm2, Terminal or Ghostty. Run it on the Mac.';
  }
  if (terms.can(window, TermCap.line)) return null;
  return "${terms.hostOf(window)?.label ?? 'This terminal'} can't take a typed line, so run the command on the Mac.";
}

/// One session's screen followed for pickers: when it was last told to look
/// soon (a command, an answer, a key) and last saw a change, and what the
/// phone typed into the current picker's search.
class _MenuWatch {
  DateTime armed = DateTime.now();
  DateTime changed = DateTime.now();
  String query = '';
  Completer<void>? _wake;

  /// Reads soon again, for a while.
  void arm() {
    armed = changed = DateTime.now();
    wake();
  }

  void wake() {
    final c = _wake;
    _wake = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Waits [d], or less if woken.
  Future<void> sleep(Duration d) {
    final c = _wake = Completer<void>();
    final timer = Timer(d, wake);
    return c.future.whenComplete(timer.cancel);
  }
}
