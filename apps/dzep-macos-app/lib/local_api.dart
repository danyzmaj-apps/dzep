import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dzep_core/idea.dart';
import 'package:dzep_core/store.dart';
import 'package:dzep_macos/live_hub.dart';
import 'package:flutter/foundation.dart';

/// The terminal's way in (`/idea`, `/todo` and `/note` in omp and Claude
/// Code, and their live sessions): HTTP on 127.0.0.1 at a random port,
/// guarded by a random token. Both are written to `~/.config/dzep/cli.json`
/// (mode 600; `DZEP_CLI_JSON` names another file) for the clients to read.
///
///   GET   /v1/ping                 → {"app": "dzep", "pid"}: this Džep is up
///   GET   /v1/ideas?project=NAME   → {"ideas": [...]}, oldest first
///   GET   /v1/ideas?kind=todo      → {"ideas": [...]}, open todos, oldest first
///   GET   /v1/ideas?kind=note      → {"ideas": [...]}, notes, oldest first
///   POST  /v1/ideas                {title, kind?, notes?, project?} → {"idea": {...}}
///                                  (a note: its text in title, or title + notes)
///   PATCH /v1/ideas/ID             {done} (todos only) → {"idea": {...}}
///   POST  /v1/notify               {title, body?} → {"sent": bool}: push to the iPhone
///                                  if nobody has used this Mac for a minute
///   GET   /v1/live                 WebSocket: a coding session reporting itself (omp's
///                                  integrations/omp/live.ts, lib/live_hub.dart)
///   POST  /v1/live/http            {conn?, frames, wait?} → {conn, frames}: the same over
///                                  HTTP long polls (the Claude Code plugin); lib/live.dart
///
/// Writes go through the [IdeaStore], so they sync like any other edit.
class LocalApi {
  LocalApi(this._store, this._notify, this._live, {File? file}) : file = file ?? _defaultFile();

  final IdeaStore? Function() _store;

  /// Pushes a notification to the user's iPhones; false when it didn't go
  /// (someone is at the Mac, no iPhone, offline).
  final Future<bool> Function(String title, String body) _notify;
  final LiveHub _live;
  HttpServer? _server;
  late final String _token = List.generate(
    32,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  /// What this app wrote to [file].
  String? _written;
  Timer? _watch;

  /// How often [file] is checked for another Džep having taken it over.
  static const _watchEvery = Duration(seconds: 5);

  /// HTTP long-poll connections (/v1/live/http) by id.
  final _polls = <String, _PollLink>{};

  /// How long a long poll waits for frames from the Mac.
  static const pollHold = Duration(seconds: 25);

  /// Where the port and token go: `~/.config/dzep/cli.json`, or the file
  /// `DZEP_CLI_JSON` names.
  final File file;

  static File _defaultFile() {
    final env = Platform.environment;
    final path = env['DZEP_CLI_JSON'];
    return File(path != null && path.isNotEmpty ? path : '${env['HOME']}/.config/dzep/cli.json');
  }

  /// The port it listens on, once started.
  int? get port => _server?.port;

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(
      (req) => unawaited(switch (req.uri.path) {
        '/v1/live' => _upgrade(req),
        '/v1/live/http' => _poll(req),
        _ => _handle(req),
      }),
    );
    _written = jsonEncode({'port': server.port, 'token': _token, 'pid': pid});
    await _write();
    _watch = Timer.periodic(_watchEvery, (_) => unawaited(_reclaim()));
  }

  Future<void> stop() async {
    _watch?.cancel();
    await _server?.close(force: true);
    for (final p in _polls.values.toList()) {
      await p.close();
    }
    // Another Džep may have it now.
    final f = file;
    if (f.existsSync() && f.readAsStringSync() == _written) f.deleteSync();
  }

  /// Writes [_written] to [file] as a whole (a reader never sees half of it),
  /// private before the token goes in.
  Future<void> _write() async {
    final f = file;
    await f.parent.create(recursive: true);
    await Process.run('chmod', ['700', f.parent.path]);
    final tmp = File('${f.path}.$pid.tmp');
    await tmp.writeAsString('');
    await Process.run('chmod', ['600', tmp.path]);
    await tmp.writeAsString(_written!, flush: true);
    await tmp.rename(f.path);
  }

  /// Another Džep (a debug build, say) took [file] over and has quit or
  /// died since, leaving the terminal pointed at nothing: this one's address
  /// goes back.
  Future<void> _reclaim() async {
    final f = file;
    String? text;
    try {
      text = f.existsSync() ? await f.readAsString() : null;
    } on FileSystemException {
      text = null;
    }
    if (!await shouldReclaim(text, _written!, answers: _answers)) return;
    debugPrint('Džep: ${f.path} named no running Džep; writing this one back');
    await _write();
  }

  /// Whether cli.json as it reads now ([text], null when missing) should
  /// give way to [ours]: it's gone or unreadable, or names a Džep that
  /// doesn't [answers] at its port with its token anymore.
  @visibleForTesting
  static Future<bool> shouldReclaim(
    String? text,
    String ours, {
    required Future<bool> Function(int port, String token) answers,
  }) async {
    if (text == ours) return false;
    final Object? json;
    try {
      json = jsonDecode(text ?? '');
    } on FormatException {
      return true;
    }
    if (json is! Map || json['port'] is! int || json['token'] is! String) return true;
    return !await answers(json['port'] as int, json['token'] as String);
  }

  /// A Džep answers /v1/ping at [port] with [token].
  static Future<bool> _answers(int port, String token) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.get('127.0.0.1', port, '/v1/ping');
      req.headers.set('authorization', 'Bearer $token');
      final res = await req.close().timeout(const Duration(seconds: 2));
      await res.drain<void>();
      return res.statusCode == 200;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _upgrade(HttpRequest req) async {
    if (req.headers.value('authorization') != 'Bearer $_token' || !WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    await _live.accept(ws.where((f) => f is String).cast<String>(), SocketLink(ws));
  }

  /// One long poll: the extension's frames go to its connection in order,
  /// and the answer carries the Mac's, waiting [pollHold] for some when
  /// asked to. A request without a connection opens one.
  Future<void> _poll(HttpRequest req) async {
    final res = req.response..headers.contentType = ContentType.json;
    try {
      if (req.method != 'POST') {
        res.statusCode = HttpStatus.methodNotAllowed;
      } else if (req.headers.value('authorization') != 'Bearer $_token') {
        res
          ..statusCode = HttpStatus.forbidden
          ..write(jsonEncode({'error': 'Bad token.'}));
      } else {
        final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
        final id = body['conn'] as String?;
        final _PollLink? link;
        if (id == null) {
          link = _PollLink(_newId(), _polls.remove);
          _polls[link.id] = link;
          unawaited(_live.accept(link.frames, link));
        } else {
          link = _polls[id];
        }
        final out = await link?.exchange([
          for (final f in body['frames'] as List? ?? const []) jsonEncode(f),
        ], hold: body['wait'] == true ? pollHold : null);
        // The agent is quitting: its session ends now.
        if (body['close'] == true) await link?.close();
        if (out == null) {
          res
            ..statusCode = HttpStatus.notFound
            ..write(jsonEncode({'error': 'No such connection: say hello again.'}));
        } else {
          // The hub's frames are JSON already.
          res.write('{"conn":${jsonEncode(link!.id)},"frames":[${out.join(',')}]}');
        }
      }
    } on Object catch (e) {
      debugPrint('Džep: live poll: $e');
      res
        ..statusCode = HttpStatus.badRequest
        ..write(jsonEncode({'error': 'Bad request: $e'}));
    }
    try {
      await res.close();
    } on Object catch (e) {
      // The extension gave up on a long poll.
      debugPrint('Džep: live poll: $e');
    }
  }

  static String _newId() =>
      List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  Future<void> _handle(HttpRequest req) async {
    final res = req.response..headers.contentType = ContentType.json;
    try {
      final (status, body) = await _route(req);
      res
        ..statusCode = status
        ..write(jsonEncode(body));
    } on Object catch (e) {
      debugPrint('Džep: API error: $e');
      res
        ..statusCode = 400
        ..write(jsonEncode({'error': 'Bad request: $e'}));
    }
    await res.close();
  }

  Future<(int, Map<String, dynamic>)> _route(HttpRequest req) async {
    if (req.headers.value('authorization') != 'Bearer $_token') return (403, {'error': 'Bad token.'});
    final path = req.uri.pathSegments;
    if (req.method == 'GET' && path.length == 2 && path[0] == 'v1' && path[1] == 'ping') {
      return (200, {'app': 'dzep', 'pid': pid});
    }
    final store = _store();
    if (store == null) return (401, {'error': 'Sign in to Džep first.'});

    // A coding session finished (omp's agent_end): tell the iPhone, unless
    // someone is at this Mac.
    if (req.method == 'POST' && path.length == 2 && path[0] == 'v1' && path[1] == 'notify') {
      final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
      final title = (body['title'] as String? ?? '').trim();
      if (title.isEmpty) return (400, {'error': 'title is required.'});
      return (200, {'sent': await _notify(title, (body['body'] as String? ?? '').trim())});
    }

    if (path.length < 2 || path[0] != 'v1' || path[1] != 'ideas') return (404, {'error': 'Not found.'});

    if (req.method == 'GET' && path.length == 2) {
      final query = req.uri.queryParameters;
      final project = query['project'];
      final ideas =
          (switch (query['kind']) {
              'todo' => store.openTodos,
              'note' => store.notes,
              _ => store.ideas,
            }).where((i) => project == null || i.project == project).toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return (
        200,
        {
          'ideas': [for (final i in ideas) i.toApi()],
        },
      );
    }

    final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;

    if (req.method == 'POST' && path.length == 2) {
      final title = (body['title'] as String? ?? '').trim();
      if (title.isEmpty) return (400, {'error': 'title is required.'});
      final notes = (body['notes'] as String? ?? '').trim();
      final idea = switch (Kind.parse(body['kind'])) {
        Kind.note => store.addNote(notes.isEmpty ? title : '$title\n$notes'),
        final kind => store.add(title: title, kind: kind, notes: notes, project: body['project'] as String? ?? ''),
      };
      return (201, {'idea': idea.toApi()});
    }

    if (req.method == 'PATCH' && path.length == 3) {
      final idea = store.byId(path[2]);
      if (idea == null) return (404, {'error': 'No such item.'});
      if (!idea.isTodo) return (400, {'error': 'Only todos can be marked done.'});
      final done = body['done'];
      if (done is! bool) return (400, {'error': 'done (true/false) is required.'});
      store.update(idea, done: done);
      return (200, {'idea': idea.toApi()});
    }

    return (405, {'error': 'Method not allowed.'});
  }
}

/// One extension on the HTTP long-poll transport (/v1/live/http): its frames
/// go to the hub in the order they came, and the hub's wait here for its
/// next request. Gone, and its session with it, after [idle] without one.
class _PollLink implements LiveLink {
  _PollLink(this.id, this._gone) {
    _idleTimer = Timer(idle, () => unawaited(close()));
  }

  final String id;
  final void Function(String id) _gone;
  static const idle = Duration(seconds: 60);

  final _in = StreamController<String>();
  final _out = <String>[];
  Completer<void>? _waiting;
  Timer? _idleTimer;
  int _active = 0;
  bool _closed = false;

  /// The extension's frames, for LiveHub.accept.
  Stream<String> get frames => _in.stream;

  @override
  void send(String frame) {
    if (_closed) return;
    _out.add(frame);
    _wake();
  }

  void _wake() {
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _idleTimer?.cancel();
    _wake();
    _gone(id);
    await _in.close();
  }

  /// One request: [frames] in, then the hub's out, waiting up to [hold] for
  /// some when there are none yet (a newer wait ends an older one). Null
  /// once closed.
  Future<List<String>?> exchange(List<String> frames, {Duration? hold}) async {
    if (_closed) return null;
    _active++;
    _idleTimer?.cancel();
    try {
      frames.forEach(_in.add);
      if (_out.isEmpty && hold != null) {
        _wake();
        final w = _waiting = Completer<void>();
        await w.future.timeout(hold, onTimeout: () {});
      }
      final out = [..._out];
      _out.clear();
      return out;
    } finally {
      if (--_active == 0 && !_closed) _idleTimer = Timer(idle, () => unawaited(close()));
    }
  }
}
