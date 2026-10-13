import 'dart:convert';
import 'dart:io';

import 'package:dzep_core/chat.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A Supabase client whose `ask` function answers with [ask]; every other
/// request finds nothing.
SupabaseClient server(http.Response Function(Map<String, dynamic> body) ask) => SupabaseClient(
  'https://abc.supabase.co',
  'sb_publishable_x',
  httpClient: MockClient((req) async {
    if (req.url.path == '/functions/v1/ask') return ask(jsonDecode(req.body) as Map<String, dynamic>);
    return http.Response('[]', 200, headers: {'content-type': 'application/json'});
  }),
);

http.Response json(int status, Object body) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  late Directory dir;
  late File cache;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('dzep-chat-');
    cache = File('${dir.path}/chats-u.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('no AI on the server: Ask is missing one, and stays so from the cache while offline', () async {
    final store = await ChatStore.cached(server((_) => json(200, {'configured': false})), 'u', cache);
    expect(store.aiMissing, isFalse, reason: 'unknown until the server says');

    await store.checkAi();
    expect(store.aiMissing, isTrue);
    await store.close();

    final offline = await ChatStore.cached(server((_) => throw const SocketException('offline')), 'u', cache);
    expect(offline.aiMissing, isTrue);
    await offline.checkAi();
    expect(offline.aiMissing, isTrue, reason: 'an unreachable server leaves the last answer');
    await offline.close();
  });

  test('connecting one later shows up on the next check, model and all', () async {
    var configured = false;
    final store = await ChatStore.cached(
      server(
        (_) => json(
          200,
          configured
              ? {'configured': true, 'model': 'gpt-5-mini', 'base_url': 'https://api.openai.com/v1'}
              : {'configured': false},
        ),
      ),
      'u',
      cache,
    );
    await store.checkAi();
    expect(store.aiMissing, isTrue);

    configured = true;
    await store.checkAi();
    expect(store.aiMissing, isFalse);
    expect(store.ai, const AiStatus(connected: true, model: 'gpt-5-mini', baseUrl: 'https://api.openai.com/v1'));
    await store.close();
  });

  test('an older server, which can’t say, leaves Ask as it was', () async {
    final store = await ChatStore.cached(
      server((_) => json(400, {'error': 'chat_id (uuid) and a question or images are required'})),
      'u',
      cache,
    );
    expect(await store.checkAi(), isNull);
    expect(store.aiMissing, isFalse);
    await store.close();
  });

  test('a question the server turns away for want of a key marks Ask missing, and no more go out', () async {
    var questions = 0;
    final store = await ChatStore.cached(
      server((body) {
        if (body['action'] == 'status') return json(200, {'configured': true});
        questions++;
        return json(500, {'error': 'No AI is connected yet.', 'configured': false});
      }),
      'u',
      cache,
    );

    await store.send('What is 2 + 2?');
    expect(store.aiMissing, isTrue);
    expect(store.current!.messages.last.error, 'No AI is connected yet.');
    expect(questions, 1);

    await store.send('Still there?');
    expect(questions, 1);
    expect(store.current!.messages, hasLength(2));
    await store.close();
  });
}
