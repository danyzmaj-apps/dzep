import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dzep/idea.dart';
import 'package:dzep/store.dart';
import 'package:flutter/foundation.dart';

/// The terminal's way in (omp's `/idea` and `/todo`): HTTP on 127.0.0.1 at
/// a random port, guarded by a random token. Both are written to
/// `~/.config/dzep/cli.json` (mode 600) for the client to read.
///
///   GET   /v1/ideas?project=NAME   → {"ideas": [...]}, oldest first
///   GET   /v1/ideas?kind=todo      → {"ideas": [...]}, open todos, oldest first
///   POST  /v1/ideas                {title, kind?, notes?, project?} → {"idea": {...}}
///   PATCH /v1/ideas/ID             {status} (idea) or {done} (todo) → {"idea": {...}}
///
/// Writes go through the [IdeaStore], so they sync like any other edit.
class LocalApi {
  LocalApi(this._store);

  final IdeaStore? Function() _store;
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
    await f.writeAsString(jsonEncode({'port': server.port, 'token': _token, 'pid': pid}));
    await Process.run('chmod', ['600', f.path]);
    server.listen((req) => unawaited(_handle(req)));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    if (file.existsSync()) file.deleteSync();
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
    if (path.length < 2 || path[0] != 'v1' || path[1] != 'ideas') return (404, {'error': 'Not found.'});

    if (req.method == 'GET' && path.length == 2) {
      final query = req.uri.queryParameters;
      final project = query['project'];
      final ideas =
          (query['kind'] == 'todo' ? store.openTodos : store.ideas)
              .where((i) => project == null || i.project == project)
              .toList()
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
      final kind = body['kind'] == 'todo' ? Kind.todo : Kind.idea;
      final idea = store.add(
        title: title,
        kind: kind,
        notes: body['notes'] as String? ?? '',
        project: body['project'] as String? ?? '',
      );
      return (201, {'idea': idea.toApi()});
    }

    if (req.method == 'PATCH' && path.length == 3) {
      final idea = store.byId(path[2]);
      if (idea == null) return (404, {'error': 'No such item.'});
      if (idea.isTodo) {
        final done = body['done'];
        if (done is! bool) return (400, {'error': 'done (true/false) is required for a todo.'});
        store.update(idea, done: done);
        return (200, {'idea': idea.toApi()});
      }
      final status = Status.values.where((s) => s.name == body['status']).firstOrNull;
      if (status == null) {
        return (400, {'error': 'status must be one of ${Status.values.map((s) => s.name).join(', ')}.'});
      }
      store.update(idea, status: status);
      return (200, {'idea': idea.toApi()});
    }

    return (405, {'error': 'Method not allowed.'});
  }
}
