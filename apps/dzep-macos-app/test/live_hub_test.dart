import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dzep_core/live.dart';
import 'package:dzep_macos/live_hub.dart';
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

  void hello({
    String? window = 'kitty-1/7',
    String id = 's1',
    List<Map<String, dynamic>> items = const [],
    List<Map<String, dynamic>> commands = const [],
  }) => send({
    't': 'hello',
    'v': 1,
    'session': {'id': id, 'title': 'Fix bug', 'cwd': '/Users/me/Dev/dzep', 'model': 'm'},
    'window': window,
    'pid': 42,
    'busy': false,
    'items': items,
    'older': false,
    'commands': commands,
  });
}

void main() {
  late HttpServer server;
  late LiveHub hub;

  setUp(() async {
    hub = LiveHub();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        await hub.accept(ws.cast<String>(), SocketLink(ws));
      });
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

  test("a reported term names the window: tmux's pane over kitty variables leaked into it", () async {
    (await connect()).send({
      't': 'hello',
      'v': 1,
      'session': {'id': 's1', 'cwd': '/Users/me/Dev/dzep'},
      // A newer extension still sends kitty's `window` from the leaked variables.
      'window': 'kitty-23224/116',
      'term': {
        'TERM_PROGRAM': 'tmux',
        'KITTY_WINDOW_ID': '116',
        'KITTY_PID': '23224',
        'TMUX': '/private/tmp/tmux-501/default,4226,0',
        'TMUX_PANE': '%0',
      },
      'pid': 42,
      'items': const <Object>[],
    });
    await until(() => hub['tmux:default/0'] != null);
    expect(hub['kitty-23224/116'], isNull);
  });

  test('a term that names no window keys the session by pid, not by the leaked kitty window', () async {
    (await connect()).send({
      't': 'hello',
      'v': 1,
      'session': {'id': 's1', 'cwd': '/Users/me/Dev/dzep'},
      'window': 'kitty-23224/116',
      'term': {'TERM_PROGRAM': 'ghostty', 'KITTY_WINDOW_ID': '116', 'KITTY_PID': '23224', 'tty': '/dev/ttys011'},
      'pid': 42,
      'items': const <Object>[],
    });
    await until(() => hub['pid:42'] != null);
    expect(hub['kitty-23224/116'], isNull);
  });

  test('slash commands come with the hello and change with a meta that has them', () async {
    final ext = await connect();
    ext.hello(
      commands: [
        {'name': 'new', 'description': 'Start a new session'},
        {'name': 'review'},
      ],
    );
    await until(() => hub['kitty-1/7'] != null);
    final s = hub['kitty-1/7']!;
    expect(s.summary.commands, [(name: 'new', description: 'Start a new session'), (name: 'review', description: '')]);
    ext.send({'t': 'meta', 'ctx': 40});
    await until(() => s.ctx == 40);
    expect(s.commands.length, 2);
    ext.send({
      't': 'meta',
      'commands': [
        {'name': 'skill:pdf', 'description': 'Read PDFs'},
      ],
    });
    await until(() => s.commands.length == 1);
    expect(s.commands.single.name, 'skill:pdf');
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

  test('a plan review is an event; its options read off the screen update the ask without another', () async {
    final ext = await connect();
    final events = <LiveEvent>[];
    hub.events.listen(events.add);
    var changes = 0;
    hub.changes.listen((_) => changes++);
    ext
      ..hello()
      ..send({
        't': 'ask',
        'ask': {'kind': 'plan', 'id': 'call9', 'title': 'notes-plan'},
      });
    await until(() => events.length == 1);
    final asked = (events.single as LiveAsked).ask;
    expect(asked.isPlan, isTrue);
    expect(asked.text, 'Plan ready: notes-plan');
    expect(asked.options, isEmpty);

    final before = changes;
    const read = LiveAsk.plan(
      'call9',
      title: 'notes-plan',
      options: ['Approve and execute', 'Refine plan'],
      selected: 1,
    );
    expect(hub.updateAsk('kitty-1/7', 'call9', read), isTrue);
    expect(changes, before + 1);
    expect(hub['kitty-1/7']!.summary.toJson()['ask'], read.toJson());
    // An ask that's no longer there isn't brought back.
    expect(hub.updateAsk('kitty-1/7', 'other', read), isFalse);
    expect(hub.updateAsk('kitty-1/7', 'call9', null), isTrue);
    expect(hub['kitty-1/7']!.ask, isNull);
    expect(hub.updateAsk('kitty-1/7', 'call9', read), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events, hasLength(1));
  });

  test("a picker read off the screen takes a free ask's place, never omp's, and makes no push", () async {
    final ext = await connect();
    final events = <LiveEvent>[];
    hub.events.listen(events.add);
    ext.hello();
    await until(() => hub['kitty-1/7'] != null);
    const menu = LiveAsk.menu('menu-1', title: 'Select theme', items: [(label: 'dark', detail: '')]);
    expect(hub.updateAsk('kitty-1/7', null, menu), isTrue);
    expect(hub['kitty-1/7']!.summary.ask?.isMenu, isTrue);
    // Another picker opened from it (/model, then its thinking level) replaces it.
    const next = LiveAsk.menu('menu-2', title: 'Thinking level', items: [(label: 'high', detail: '')]);
    expect(hub.updateAsk('kitty-1/7', 'menu-1', next), isTrue);
    // omp's own question wins, and a picker doesn't push it aside.
    ext.send({
      't': 'ask',
      'ask': {'kind': 'plan', 'id': 'call9', 'title': 'notes-plan'},
    });
    await until(() => hub['kitty-1/7']!.ask?.isPlan ?? false);
    expect(hub.updateAsk('kitty-1/7', null, menu), isFalse);
    expect(hub.updateAsk('kitty-1/7', 'menu-2', null), isFalse);
    expect(hub['kitty-1/7']!.ask?.id, 'call9');
    expect(events.whereType<LiveAsked>().map((e) => e.ask.id), ['call9']);
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
