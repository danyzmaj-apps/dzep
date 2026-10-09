import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dzep/idea.dart';
import 'package:dzep/live_hub.dart';
import 'package:dzep/store.dart';
import 'package:flutter/foundation.dart';

/// The terminal's way in (omp's `/idea`, `/todo` and `/note`): HTTP on
/// 127.0.0.1 at a random port, guarded by a random token. Both are written to
/// `~/.config/dzep/cli.json` (mode 600) for the client to read.
///
///   GET   /v1/ideas?project=NAME   → {"ideas": [...]}, oldest first
///   GET   /v1/ideas?kind=todo      → {"ideas": [...]}, open todos, oldest first
///   GET   /v1/ideas?kind=note      → {"ideas": [...]}, notes, oldest first
///   POST  /v1/ideas                {title, kind?, notes?, project?} → {"idea": {...}}
///                                  (a note: its text in title, or title + notes)
///   PATCH /v1/ideas/ID             {done} (todos only) → {"idea": {...}}
///   POST  /v1/notify               {title, body?} → {"sent": bool}: push to the iPhone
///                                  if nobody has used this Mac for a minute
///   GET   /v1/live                 WebSocket: an omp session reporting itself
///                                  (integrations/omp/live.ts, lib/live_hub.dart)
///
/// Writes go through the [IdeaStore], so they sync like any other edit.
class LocalApi {
  LocalApi(this._store, this._notify, this._live);

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

  static File get file => File('${Platform.environment['HOME']}/.config/dzep/cli.json');

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    final f = file;
    await f.parent.create(recursive: true);
    // Private before the token goes in, so it's never readable by others.
    await Process.run('chmod', ['700', f.parent.path]);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString('');
    await Process.run('chmod', ['600', tmp.path]);
    await tmp.writeAsString(jsonEncode({'port': server.port, 'token': _token, 'pid': pid}), flush: true);
    await tmp.rename(f.path);
    server.listen((req) => unawaited(req.uri.path == '/v1/live' ? _upgrade(req) : _handle(req)));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    if (file.existsSync()) file.deleteSync();
  }

  Future<void> _upgrade(HttpRequest req) async {
    if (req.headers.value('authorization') != 'Bearer $_token' || !WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    await _live.accept(await WebSocketTransformer.upgrade(req));
  }

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
    final store = _store();
    if (store == null) return (401, {'error': 'Sign in to Džep first.'});
    final path = req.uri.pathSegments;

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
