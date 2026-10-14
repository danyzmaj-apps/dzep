import 'dart:convert';
import 'dart:io';

import 'package:dzep_core/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The `ideas` table of one user, as the server keeps it: every write gets
/// the server's clock as updated_at, and a pull returns what changed after
/// `updated_at=gt.<cursor>`.
class FakeServer {
  final rows = <String, Map<String, dynamic>>{};
  var _clock = DateTime.utc(2026, 10, 1, 12);

  /// Called with each row a push wrote, before the push gets its answer:
  /// realtime's echo can beat the HTTP response.
  void Function(Map<String, dynamic> row)? echo;

  Map<String, dynamic> write(Map<String, dynamic> row) {
    _clock = _clock.add(const Duration(seconds: 1));
    final saved = {...?rows[row['id']], ...row, 'user_id': 'u', 'updated_at': _clock.toIso8601String()};
    rows[row['id'] as String] = saved;
    return saved;
  }

  /// Another device adding [title] while this one isn't looking.
  Map<String, dynamic> addElsewhere(String id, String title) =>
      write({'id': id, 'kind': 'idea', 'title': title, 'created_at': _clock.toIso8601String()});

  late final client = SupabaseClient(
    'https://abc.supabase.co',
    'sb_publishable_x',
    httpClient: MockClient((req) async {
      if (req.url.path != '/rest/v1/ideas') return _json(req, 404, {'message': 'not here'});
      if (req.method == 'POST') {
        final saved = [for (final r in jsonDecode(req.body) as List<dynamic>) write(r as Map<String, dynamic>)]
          ..forEach(echo ?? (_) {});
        return _json(req, 201, saved);
      }
      final since = DateTime.parse(req.url.queryParameters['updated_at']!.replaceFirst('gt.', ''));
      final changed = rows.values.where((r) => DateTime.parse(r['updated_at'] as String).isAfter(since)).toList()
        ..sort((a, b) => (a['updated_at'] as String).compareTo(b['updated_at'] as String));
      return _json(req, 200, changed);
    }),
  );

  static http.Response _json(http.Request req, int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    request: req,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  late Directory dir;
  late File cache;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('dzep-ideas-');
    cache = File('${dir.path}/ideas-u.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('back online, the echo of its own push never makes the pull skip what changed while away', () async {
    final server = FakeServer();
    final store = await IdeaStore.cached(server.client, 'u', cache, 'mac');
    await store.syncNow();
    server.echo = store.receive;

    // While this device was offline another one added an idea, and this one
    // wrote one of its own. Back online it pushes, realtime echoes its row
    // back, then it pulls.
    store.add(title: 'written offline');
    server.addElsewhere('00000000-0000-0000-0000-0000000000e1', 'added on the phone');
    await store.syncNow();

    expect(store.byId('00000000-0000-0000-0000-0000000000e1')?.title, 'added on the phone');
    await store.close();
  });

  test("a realtime event ahead of a lost one doesn't hide the lost one from the next pull", () async {
    final server = FakeServer();
    final store = await IdeaStore.cached(server.client, 'u', cache, 'mac');
    await store.syncNow();

    server.addElsewhere('00000000-0000-0000-0000-0000000000e1', 'its event was lost');
    store.receive(server.addElsewhere('00000000-0000-0000-0000-0000000000e2', 'its event arrived'));
    await store.syncNow();

    expect([for (final i in store.ideas) i.title], unorderedEquals(['its event was lost', 'its event arrived']));
    await store.close();
  });
}
