import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dzep_core/agent.dart';
import 'package:dzep_core/live.dart';
import 'package:flutter/foundation.dart';

/// One extension's connection, whatever carries it (lib/local_api.dart): a
/// WebSocket (omp) or HTTP long polls (Claude Code).
abstract interface class LiveLink {
  /// A JSON frame to the extension.
  void send(String frame);

  Future<void> close();
}

/// A WebSocket as a [LiveLink].
class SocketLink implements LiveLink {
  SocketLink(this._ws);
  final WebSocket _ws;

  @override
  void send(String frame) => _ws.add(frame);

  @override
  Future<void> close() => _ws.close();
}

/// One coding session, as its agent's extension reports it (integrations/:
/// omp's live.ts, the Claude Code plugin).
class LiveSession {
  LiveSession._(this._link, this.key, this.log);

  final LiveLink _link;

  /// The kitty window it runs in (`kitty-<pid>/<id>`), or `pid:<pid>`.
  final String key;
  LiveLog log;
  Agent agent = Agent.omp;
  String? window;
  String id = '';
  String title = '';
  String cwd = '';
  String model = '';
  bool busy = false;
  LiveAsk? ask;
  int? ctx;
  String preview = '';
  List<LiveCommand> commands = const [];
  DateTime at = DateTime.now();

  int _req = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};

  /// The folder's name, for notifications.
  String get project => cwd.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => cwd);

  LiveSummary get summary => LiveSummary(
    key: key,
    id: id,
    agent: agent,
    window: window,
    title: title,
    cwd: cwd,
    model: model,
    busy: busy,
    ask: ask,
    ctx: ctx,
    preview: preview,
    at: at,
    epoch: log.epoch,
    seq: log.seq,
    older: log.older,
    commands: commands,
  );

  Future<Map<String, dynamic>> _request(String type, Map<String, dynamic> payload, Duration timeout) async {
    final req = ++_req;
    final done = _pending[req] = Completer();
    _link.send(jsonEncode({'t': type, 'req': req, ...payload}));
    try {
      final reply = await done.future.timeout(timeout);
      final error = reply['error'] as String?;
      if (error != null) throw LiveException(error);
      return reply;
    } on TimeoutException {
      throw LiveException('${agent.label} did not answer.');
    } finally {
      _pending.remove(req);
    }
  }

  void _fail() {
    for (final c in _pending.values) {
      c.completeError(LiveException('The ${agent.label} session ended.'));
    }
    _pending.clear();
  }
}

class LiveException implements Exception {
  const LiveException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Something worth a notification.
sealed class LiveEvent {
  const LiveEvent(this.session);
  final LiveSession session;
}

/// The agent stopped and isn't about to go on by itself.
class LiveFinished extends LiveEvent {
  const LiveFinished(super.session, this.summary);
  final String summary;
}

/// The agent asks a question, wants a tool approved, or has a plan for review.
class LiveAsked extends LiveEvent {
  const LiveAsked(super.session, this.ask);
  final LiveAsk ask;
}

/// The coding sessions on this Mac: their extensions connect to the local
/// API (lib/local_api.dart) and keep it up to date; the terminal bridge
/// passes them on to the phone.
class LiveHub {
  final _byKey = <String, LiveSession>{};

  /// Transcript changes, per session.
  Stream<(LiveSession, List<LiveOp>)> get ops => _ops.stream;
  final _ops = StreamController<(LiveSession, List<LiveOp>)>.broadcast(sync: true);

  /// A session came, went, or its summary changed.
  Stream<void> get changes => _changes.stream;
  final _changes = StreamController<void>.broadcast(sync: true);

  Stream<LiveEvent> get events => _events.stream;
  final _events = StreamController<LiveEvent>.broadcast();

  Iterable<LiveSession> get sessions => _byKey.values;
  LiveSession? operator [](String key) => _byKey[key];

  /// Serves one extension, whose JSON [frames] come in order over [link],
  /// until they end.
  Future<void> accept(Stream<String> frames, LiveLink link) async {
    LiveSession? session;
    try {
      await for (final frame in frames) {
        final Map<String, dynamic> m;
        try {
          m = jsonDecode(frame) as Map<String, dynamic>;
        } on FormatException {
          continue;
        }
        if (m['t'] == 'hello') {
          session = _hello(link, session, m);
        } else if (session != null && identical(_byKey[session.key], session)) {
          _handle(session, m);
        }
      }
    } on Object catch (e) {
      debugPrint('Džep: live session: $e');
    } finally {
      if (session != null) {
        session._fail();
        if (identical(_byKey[session.key], session)) {
          _byKey.remove(session.key);
          _changes.add(null);
        }
      }
    }
  }

  LiveSession _hello(LiveLink link, LiveSession? current, Map<String, dynamic> m) {
    final s = (m['session'] as Map?)?.cast<String, dynamic>() ?? const {};
    final window = m['window'] as String?;
    final key = window ?? 'pid:${m['pid']}';
    final log = LiveLog([
      for (final i in m['items'] as List? ?? const []) LiveItem.fromJson((i as Map).cast()),
    ], older: m['older'] == true);
    final LiveSession session;
    if (current != null && current.key == key && identical(_byKey[key], current)) {
      // Another session in the same agent (/new, /resume, /clear): a new transcript.
      session = current..log = log;
    } else {
      if (current != null && identical(_byKey[current.key], current)) _byKey.remove(current.key);
      session = LiveSession._(link, key, log);
      // The same window's previous agent, if its connection hasn't closed yet.
      final old = _byKey[key];
      if (old != null && !identical(old._link, link)) unawaited(old._link.close());
      _byKey[key] = session;
    }
    session
      ..agent = Agent.parse(m['agent'])
      ..window = window
      ..id = s['id'] as String? ?? ''
      ..title = s['title'] as String? ?? ''
      ..cwd = s['cwd'] as String? ?? ''
      ..model = s['model'] as String? ?? ''
      ..busy = m['busy'] == true
      ..ctx = (m['ctx'] as num?)?.round()
      ..ask = null
      ..commands = liveCommands(m['commands'])
      ..preview = _preview(log.items.lastWhere((i) => i.kind == ItemKind.assistant, orElse: () => _none).text)
      ..at = DateTime.now();
    _changes.add(null);
    return session;
  }

  static final _none = LiveItem(id: '', kind: ItemKind.notice);

  static String _preview(String text) {
    final line = text
        .split('\n')
        .map((l) => l.replaceAll(RegExp('[`*_#>]'), '').trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return line.length > 140 ? '${line.substring(0, 139)}…' : line;
  }

  void _handle(LiveSession s, Map<String, dynamic> m) {
    switch (m['t']) {
      case 'item':
        final item = LiveItem.fromJson((m['item'] as Map).cast());
        s.at = DateTime.now();
        _ops.add((s, [s.log.upsert(item)]));
        if (item.kind == ItemKind.assistant && item.text.isNotEmpty) {
          final preview = _preview(item.text);
          if (preview != s.preview) {
            s.preview = preview;
            _changes.add(null);
          }
        }
      case 'append':
        final op = s.log.append(m['id'] as String, m['text'] as String? ?? '');
        if (op != null) _ops.add((s, [op]));
      case 'busy':
        final busy = m['busy'] == true;
        s
          ..busy = busy
          ..at = DateTime.now();
        _changes.add(null);
        final summary = m['summary'] as String?;
        if (!busy && summary != null) _events.add(LiveFinished(s, summary));
      case 'ask':
        final ask = m['ask'] is Map ? LiveAsk.fromJson((m['ask'] as Map).cast()) : null;
        s.ask = ask;
        _changes.add(null);
        if (ask != null) _events.add(LiveAsked(s, ask));
      case 'meta':
        if (m['title'] is String) s.title = m['title'] as String;
        if (m['model'] is String) s.model = m['model'] as String;
        if (m.containsKey('ctx')) s.ctx = (m['ctx'] as num?)?.round();
        if (m['commands'] is List) s.commands = liveCommands(m['commands']);
        _changes.add(null);
      case 'reply':
        s._pending[m['req']]?.complete(m);
    }
  }

  LiveSession _session(String key) {
    final s = _byKey[key];
    if (s == null) throw const LiveException('That session has ended.');
    return s;
  }

  /// Replaces session [key]'s ask, while it's still [id] (null: while there
  /// is none), with what the Mac read off its screen: a plan review's
  /// options, a picker a slash command opened, or null once it's gone. Not
  /// the agent asking, so no event. False when the session's ask has moved
  /// on.
  bool updateAsk(String key, String? id, LiveAsk? ask) {
    final s = _byKey[key];
    if (s == null || s.ask?.id != id) return false;
    s.ask = ask;
    _changes.add(null);
    return true;
  }

  /// Where images for an agent that reads them from disk (Claude Code) wait
  /// for it; the ones older than a day go when more come.
  @visibleForTesting
  static Directory imageDir = Directory('${Directory.systemTemp.path}/dzep-images');

  /// Sends [text] (and [images]) as the person's prompt. While omp works it
  /// steers the run, or waits for the run to end with [followUp]; Claude
  /// Code always waits, and gets the images as files.
  Future<void> prompt(
    String key,
    String text, {
    List<({Uint8List bytes, String mimeType})> images = const [],
    bool followUp = false,
  }) async {
    final s = _session(key);
    final steers = s.agent.steers;
    await s._request('prompt', {
      'text': text,
      'images': [
        if (steers)
          for (final i in images) {'data': base64Encode(i.bytes), 'mimeType': i.mimeType},
      ],
      if (!steers) 'files': await _saveImages(images),
      'deliver': followUp || !steers ? 'followUp' : 'steer',
    }, const Duration(seconds: 15));
  }

  static Future<List<String>> _saveImages(List<({Uint8List bytes, String mimeType})> images) async {
    if (images.isEmpty) return const [];
    final dir = imageDir;
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      await Process.run('chmod', ['700', dir.path]);
    }
    final dayAgo = DateTime.now().subtract(const Duration(days: 1));
    for (final f in dir.listSync().whereType<File>()) {
      if (f.statSync().modified.isBefore(dayAgo)) f.deleteSync();
    }
    final random = Random.secure();
    return [
      for (final i in images)
        (File(
          '${dir.path}/${List.generate(12, (_) => random.nextInt(36).toRadixString(36)).join()}'
          '.${i.mimeType == 'image/jpeg' ? 'jpg' : 'png'}',
        )..writeAsBytesSync(i.bytes)).path,
    ];
  }

  /// Esc: stops what the agent is doing.
  Future<void> abort(String key) => _session(key)._request('abort', const {}, const Duration(seconds: 5));

  /// Fetches the items before the oldest one the hub has; they go out as ops.
  Future<void> older(String key, {int limit = 150}) async {
    final s = _session(key);
    if (!s.log.older) return;
    final log = s.log;
    final reply = await s._request('older', {'limit': limit}, const Duration(seconds: 10));
    // Another session started meanwhile: these belong to the old one.
    if (!identical(s.log, log)) return;
    final items = [for (final i in reply['items'] as List? ?? const []) LiveItem.fromJson((i as Map).cast())];
    final ops = log.addOlder(items, more: reply['older'] == true);
    if (ops.isNotEmpty) _ops.add((s, ops));
    _changes.add(null);
  }
}
