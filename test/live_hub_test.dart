import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dzep/live.dart';
import 'package:dzep/live_hub.dart';
import 'package:flutter_test/flutter_test.dart';

/// An omp extension's side of the socket.
class _Ext {
  _Ext(this.ws) {
    ws.listen((f) => received.add(jsonDecode(f as String) as Map<String, dynamic>));
  }

  final WebSocket ws;
  final received = StreamController<Map<String, dynamic>>();
  late final StreamIterator<Map<String, dynamic>> next = StreamIterator(received.stream);

  void send(Map<String, dynamic> m) => ws.add(jsonEncode(m));

  Future<Map<String, dynamic>> request() async {
    await next.moveNext();
    return next.current;
  }

  void hello({String? window = 'kitty-1/7', String id = 's1', List<Map<String, dynamic>> items = const []}) => send({
    't': 'hello',
    'v': 1,
    'session': {'id': id, 'title': 'Fix bug', 'cwd': '/Users/me/Dev/dzep', 'model': 'm'},
    'window': window,
    'pid': 42,
    'busy': false,
    'items': items,
    'older': false,
  });
}

void main() {
  late HttpServer server;
  late LiveHub hub;

  setUp(() async {
    hub = LiveHub();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((req) async => await hub.accept(await WebSocketTransformer.upgrade(req)));
  });

  tearDown(() => server.close(force: true));

  Future<_Ext> connect() async => _Ext(await WebSocket.connect('ws://127.0.0.1:${server.port}'));

  /// Waits until [check] holds (the hub reads frames asynchronously).
  Future<void> until(bool Function() check) async {
    for (var i = 0; i < 200 && !check(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(check(), isTrue);
  }

  test('a session is known by its kitty window, with its snapshot and summary', () async {
    final ext = await connect();
    ext.hello(
      items: [
        {'id': 'u', 'k': 'user', 't': 'hi'},
        {'id': 'a', 'k': 'assistant', 't': '**Done.** All tests pass\nmore'},
      ],
    );
    await until(() => hub['kitty-1/7'] != null);
    final s = hub['kitty-1/7']!;
    expect(s.log.items.map((i) => i.id), ['u', 'a']);
    expect(s.summary.preview, 'Done. All tests pass');
    expect(s.project, 'dzep');
  });

  test('outside kitty the key is the pid', () async {
    (await connect()).hello(window: null);
    await until(() => hub['pid:42'] != null);
  });

  test('items and streamed text become ops in order', () async {
    final ext = await connect();
    final ops = <LiveOp>[];
    hub.ops.listen((e) => ops.addAll(e.$2));
    ext
      ..hello()
      ..send({
        't': 'item',
        'item': {'id': 'a', 'k': 'assistant', 't': ''},
      })
      ..send({'t': 'append', 'id': 'a', 'text': 'Hel'})
      ..send({'t': 'append', 'id': 'a', 'text': 'lo'})
      ..send({'t': 'append', 'id': 'nope', 'text': 'x'});
    await until(() => ops.length == 3);
    final view = LiveView(epoch: hub['kitty-1/7']!.log.epoch);
    expect(view.apply(view.epoch, ops), isTrue);
    expect(view.items.single.text, 'Hello');
  });

  test('a finished run and a question are events; a run that will go on is not', () async {
    final ext = await connect();
    final events = <LiveEvent>[];
    hub.events.listen(events.add);
    ext
      ..hello()
      ..send({'t': 'busy', 'busy': true})
      ..send({'t': 'busy', 'busy': false})
      ..send({'t': 'busy', 'busy': false, 'summary': 'All done'})
      ..send({
        't': 'ask',
        'ask': {
          'kind': 'ask',
          'id': 'call1',
          'questions': [
            {
              'id': 'db',
              'question': 'Database?',
              'options': ['SQLite', 'Postgres'],
            },
          ],
        },
      });
    await until(() => events.length == 2);
    expect((events[0] as LiveFinished).summary, 'All done');
    expect((events[1] as LiveAsked).ask.questions!.single.options, ['SQLite', 'Postgres']);
    expect(hub['kitty-1/7']!.summary.ask?.id, 'call1');
    ext.send({'t': 'ask', 'ask': null});
    await until(() => hub['kitty-1/7']!.ask == null);
  });

  test('a prompt reaches the extension and its reply completes it; an error reply fails it', () async {
    final ext = await connect();
    ext.hello();
    await until(() => hub['kitty-1/7'] != null);
    final ok = hub.prompt('kitty-1/7', 'go on', followUp: true);
    final req = await ext.request();
    expect(req, containsPair('t', 'prompt'));
    expect(req, containsPair('text', 'go on'));
    expect(req, containsPair('deliver', 'followUp'));
    ext.send({'t': 'reply', 'req': req['req']});
    await ok;

    final failing = hub.abort('kitty-1/7');
    final abort = await ext.request();
    ext.send({'t': 'reply', 'req': abort['req'], 'error': 'Nothing to stop.'});
    await expectLater(failing, throwsA(isA<LiveException>().having((e) => e.message, 'message', 'Nothing to stop.')));
  });

  test('older items arrive as ops above the oldest', () async {
    final ext = await connect();
    final ops = <LiveOp>[];
    hub.ops.listen((e) => ops.addAll(e.$2));
    ext.send({
      't': 'hello',
      'session': {'id': 's'},
      'window': 'kitty-1/7',
      'items': [
        {'id': 'c', 'k': 'user', 't': 'c'},
      ],
      'older': true,
    });
    await until(() => hub['kitty-1/7'] != null);
    final done = hub.older('kitty-1/7');
    final req = await ext.request();
    ext.send({
      't': 'reply',
      'req': req['req'],
      'items': [
        {'id': 'a', 'k': 'user', 't': 'a'},
        {'id': 'b', 'k': 'user', 't': 'b'},
      ],
      'older': false,
    });
    await done;
    expect(hub['kitty-1/7']!.log.items.map((i) => i.id), ['a', 'b', 'c']);
    expect(hub['kitty-1/7']!.log.older, isFalse);
    expect(ops, hasLength(2));
  });

  test('/new in the same omp starts a new transcript under the same key', () async {
    final ext = await connect();
    ext.hello(
      items: [
        {'id': 'x', 'k': 'user', 't': 'old'},
      ],
    );
    await until(() => hub['kitty-1/7'] != null);
    final epoch = hub['kitty-1/7']!.log.epoch;
    ext.hello(id: 's2');
    await until(() => hub['kitty-1/7']!.id == 's2');
    expect(hub['kitty-1/7']!.log.epoch, isNot(epoch));
    expect(hub['kitty-1/7']!.log.items, isEmpty);
  });

  test('a new omp in the same window replaces the old one; its end removes it and fails what waits', () async {
    final first = await connect();
    first.hello();
    await until(() => hub['kitty-1/7'] != null);
    final pending = expectLater(hub.prompt('kitty-1/7', 'x'), throwsA(isA<LiveException>()));
    await first.request();
    final second = await connect();
    second.hello(id: 's9');
    await until(() => hub['kitty-1/7']?.id == 's9');
    await pending;
    await second.ws.close();
    await until(() => hub['kitty-1/7'] == null);
    expect(hub.sessions, isEmpty);
  });
}
