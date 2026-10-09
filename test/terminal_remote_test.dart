import 'dart:io';

import 'package:dzep/live.dart';
import 'package:dzep/terminal_remote.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late Directory dir;
  late List<(String, Map<String, dynamic>)> sent;
  final client = SupabaseClient('http://localhost:1', 'anon');

  TerminalRemote remote() =>
      TerminalRemote(client, 'u1', dir, from: 'phone', send: (event, payload) => sent.add((event, payload)));

  List<Map<String, dynamic>> syncs() => [
    for (final (e, p) in sent)
      if (e == 'sync') p,
  ];

  Map<String, dynamic> item(String id, String text, int order, int seq) =>
      LiveItem(id: id, kind: ItemKind.assistant, text: text, order: order, seq: seq).toJson();

  Map<String, dynamic> state({String epoch = 'e1', int seq = 2}) => {
    'windows': [
      {'key': 'kitty-1/1', 'title': 'omp', 'cwd': '/Users/me/x', 'program': 'omp'},
    ],
    'sessions': [
      {
        'key': 'kitty-1/1',
        'id': 's1',
        'window': 'kitty-1/1',
        'title': 'Fix it',
        'cwd': '/Users/me/x',
        'epoch': epoch,
        'seq': seq,
      },
    ],
    'projects': ['/Users/me/x'],
    'home': '/Users/me',
  };

  Map<String, dynamic> items({String to = 'phone', int seq = 2, bool last = true}) => {
    'to': to,
    'session': 'kitty-1/1',
    'epoch': 'e1',
    'seq': seq,
    'reset': true,
    'items': [item('a', 'one', 0, 1), item('b', 'two', 1, 2)],
    'last': last,
    'older': false,
  };

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dzep_terminal');
    sent = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a new remote on the same cache shows the last state and transcript before the Mac answers', () {
    remote()
      ..handle('state', state())
      ..handle('items', items())
      ..flush();

    final b = remote();
    expect(b.fromCache, isTrue);
    expect(b.stateAt, isNotNull);
    expect(b.home, '/Users/me');
    expect(b.windows.single.key, 'kitty-1/1');
    expect(b.sessions.single.title, 'Fix it');
    final v = b.view('kitty-1/1')!;
    expect(v.epoch, 'e1');
    expect(v.seq, 2);
    expect(v.items.map((i) => i.text), ['one', 'two']);

    // The first state from the Mac replaces the cached one.
    b.handle('state', state());
    expect(b.fromCache, isFalse);
  });

  test('watching asks for what the cached view misses', () {
    remote()
      ..handle('items', items())
      ..flush();
    remote().watchSession('kitty-1/1');
    expect(syncs().single, {'from': 'phone', 'session': 'kitty-1/1', 'epoch': 'e1', 'since': 2});
  });

  test('a gap in live ops syncs from what the view has', () {
    final r = remote()..watchSession('kitty-1/1');
    expect(syncs().single['since'], 0);
    r.handle('items', items());
    sent.clear();

    // seq 3 never came.
    r.handle('live', {
      'session': 'kitty-1/1',
      'epoch': 'e1',
      'ops': [
        {'s': 4, 'id': 'b', 'a': '!'},
      ],
    });
    expect(syncs().single, {'from': 'phone', 'session': 'kitty-1/1', 'epoch': 'e1', 'since': 2});
  });

  test('live ops during a sync wait for it, then apply', () {
    final r = remote()
      ..watchSession('kitty-1/1')
      ..handle('live', {
        'session': 'kitty-1/1',
        'epoch': 'e1',
        'ops': [
          {'s': 3, 'id': 'b', 'a': ' more'},
        ],
      })
      ..handle('items', items());
    expect(r.view('kitty-1/1')!.items.last.text, 'two more');
    expect(r.view('kitty-1/1')!.seq, 3);
    expect(syncs(), hasLength(1));
  });

  test('a new epoch in the state syncs the watched session', () {
    final r = remote()
      ..watchSession('kitty-1/1')
      ..handle('items', items());
    sent.clear();
    r.handle('state', state(epoch: 'e2', seq: 1));
    expect(syncs().single['epoch'], 'e1');
  });

  test('items for another phone are ignored', () {
    final r = remote()..handle('items', items(to: 'other'));
    expect(r.view('kitty-1/1'), isNull);
  });

  test('a screen diff on a version the phone missed asks for the whole screen', () {
    final r = remote()..watchWindow('w');
    sent.clear();
    r
      ..handle('screen', {
        'window': 'w',
        'v': 1,
        'lines': ['a', 'b', 'c'],
      })
      ..handle('screen', {
        'window': 'w',
        'v': 2,
        'diff': const ScreenDiff(drop: 1, keep: 2, tail: ['d']).toJson(),
      });
    expect(r.screen('w')!.lines, ['b', 'c', 'd']);
    expect(r.screen('w')!.base, 1);
    expect(syncs(), isEmpty);

    // Version 3 went missing.
    r.handle('screen', {
      'window': 'w',
      'v': 4,
      'diff': const ScreenDiff(drop: 0, keep: 3, tail: ['e']).toJson(),
    });
    expect(r.screen('w')!.lines, ['b', 'c', 'd']);
    expect(syncs().single, {'from': 'phone', 'window': 'w'});
  });

  test('a whole screen that scrolled keeps count of the lines gone', () {
    final r = remote()
      ..handle('screen', {
        'window': 'w',
        'v': 1,
        'lines': ['a', 'b', 'c', 'd'],
      })
      ..handle('screen', {
        'window': 'w',
        'v': 2,
        'lines': ['c', 'd', 'e', 'f'],
      });
    expect(r.screen('w')!.base, 2);
  });

  test('closing a watch goes back to the one under it', () {
    final r = remote();
    final unwatchSession = r.watchSession('s');
    final unwatchWindow = r.watchWindow('w');
    expect((r.watchedSession, r.watchedWindow), (null, 'w'));
    unwatchWindow();
    expect((r.watchedSession, r.watchedWindow), ('s', null));
    unwatchSession();
    expect((r.watchedSession, r.watchedWindow), (null, null));
  });

  test('session files untouched for 14 days are pruned on load', () {
    remote()
      ..handle('items', items())
      ..flush();
    final file = Directory('${dir.path}/sessions').listSync().whereType<File>().single
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 15)));
    expect(remote().view('kitty-1/1'), isNull);
    expect(file.existsSync(), isFalse);
  });
}
