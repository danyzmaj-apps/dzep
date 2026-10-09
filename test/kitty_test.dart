import 'dart:convert';
import 'dart:io';

import 'package:dzep/kitty.dart';
import 'package:flutter_test/flutter_test.dart';

/// A kitty listening on a unix socket: records each command and answers
/// with what [answer] returns, written in the given pieces (null: never).
class FakeKitty {
  FakeKitty._(this.dir, this._server);

  static Future<FakeKitty> start() async {
    // Short path: unix socket paths are limited to ~104 bytes on macOS.
    final dir = Directory('/tmp').createTempSync('kt');
    final server = await ServerSocket.bind(
      InternetAddress('${dir.path}/kitty-test', type: InternetAddressType.unix),
      0,
    );
    final fake = FakeKitty._(dir, server);
    server.listen(fake._serve);
    return fake;
  }

  final Directory dir;
  final ServerSocket _server;
  final requests = <Map<String, dynamic>>[];
  List<String>? Function(Map<String, dynamic> request) answer = (_) => [ok()];

  static String ok([Object? data]) => frame({'ok': true, 'data': ?data});
  static String frame(Map<String, Object?> reply) => '\x1bP@kitty-cmd${jsonEncode(reply)}\x1b\\';

  Kitty kitty({Duration timeout = const Duration(seconds: 5)}) => Kitty(socketDir: dir.path, timeout: timeout);

  void _serve(Socket s) {
    final buf = StringBuffer();
    s.listen((bytes) async {
      buf.write(utf8.decode(bytes));
      final text = buf.toString();
      if (!text.endsWith('\x1b\\')) return;
      expect(text, startsWith('\x1bP@kitty-cmd'));
      final request = jsonDecode(text.substring('\x1bP@kitty-cmd'.length, text.length - 2)) as Map<String, dynamic>;
      requests.add(request);
      final pieces = answer(request);
      if (pieces == null) return;
      for (final p in pieces) {
        s.add(utf8.encode(p));
        await s.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await s.close();
    }, onError: (Object _) {});
  }

  Future<void> stop() async {
    await _server.close();
    dir.deleteSync(recursive: true);
  }
}

void main() {
  late FakeKitty fake;
  setUp(() async => fake = await FakeKitty.start());
  tearDown(() => fake.stop());

  test('frames each command as kitty-cmd JSON with version and payload', () async {
    await fake.kitty().close('kitty-test/7');
    expect(fake.requests, [
      {
        'cmd': 'close-window',
        'version': [0, 20, 0],
        'payload': {'match': 'id:7'},
      },
    ]);
  });

  test('reads an answer that arrives in several writes', () async {
    const colors = 'foreground #a0b0c0\nbackground #010203\ncolor1     #ff0000\n';
    final whole = FakeKitty.ok(colors);
    fake.answer = (_) => [whole.substring(0, 10), whole.substring(10, 40), whole.substring(40, whole.length - 1), r'\'];
    final c = await fake.kitty().colors('kitty-test/1');
    expect(c['fg'], 0xA0B0C0);
    expect(c['bg'], 0x010203);
    expect((c['palette']! as List)[1], 0xFF0000);
  });

  test('a multi-line send types each line, Shift+Enter between, Enter last', () async {
    await fake.kitty().send('kitty-test/3', 'one\n\ntwo', enter: true);
    final sent = [
      for (final r in fake.requests) (cmd: r['cmd'] as String, payload: r['payload'] as Map<String, dynamic>),
    ];
    String show(({String cmd, Map<String, dynamic> payload}) r) {
      if (r.cmd == 'send-key') return 'key ${(r.payload['keys'] as List).join(' ')}';
      return '${r.cmd} ${r.payload['data']}';
    }

    expect(sent.map(show), [
      'send-text text:one',
      'key shift+enter',
      'key shift+enter',
      'send-text text:two',
      'key enter',
    ]);
    for (final r in sent) {
      expect(r.payload['match'], 'id:3');
      if (r.cmd == 'send-text') expect(r.payload['bracketed_paste'], 'disable');
    }
  });

  test('pressKeys sends all names in one command; press refuses keys the phone may not press', () async {
    final kitty = fake.kitty();
    await kitty.pressKeys('kitty-test/2', ['down', 'down', 'enter']);
    expect(fake.requests.single['payload'], {
      'match': 'id:2',
      'keys': ['down', 'down', 'enter'],
    });
    await expectLater(kitty.press('kitty-test/2', 'ctrl+v'), throwsA(isA<KittyException>()));
    expect(fake.requests, hasLength(1));
  });

  test('windows() reads the ls JSON kitty nests inside data', () async {
    final ls = [
      {
        'tabs': [
          {
            'title': 'work',
            'windows': [
              {
                'id': 4,
                'title': 'omp: dzep',
                'is_focused': true,
                'cwd': '/x',
                'cmdline': ['-zsh'],
                'foreground_processes': [
                  {
                    'cwd': '/Users/me/dzep',
                    'cmdline': ['/opt/homebrew/bin/omp', '--resume'],
                  },
                ],
              },
              {
                'id': 5,
                'title': 'shell',
                'cwd': '/Users/me',
                'cmdline': ['-zsh'],
              },
            ],
          },
        ],
      },
    ];
    fake.answer = (_) => [FakeKitty.ok(jsonEncode(ls))];
    final windows = await fake.kitty().windows();
    expect(
      [for (final w in windows) w.toJson()],
      [
        {
          'key': 'kitty-test/4',
          'title': 'omp: dzep',
          'tab': 'work',
          'cwd': '/Users/me/dzep',
          'program': 'omp',
          'focused': true,
        },
        {
          'key': 'kitty-test/5',
          'title': 'shell',
          'tab': 'work',
          'cwd': '/Users/me',
          'program': 'zsh',
          'focused': false,
        },
      ],
    );
    expect(windows.first.isOmp, isTrue);
  });

  test('a window kitty no longer has reads as gone; other errors pass through', () async {
    fake.answer = (_) => [
      FakeKitty.frame({'ok': false, 'error': 'No matching windows for expression: id:9'}),
    ];
    await expectLater(
      fake.kitty().press('kitty-test/9', 'esc'),
      throwsA(isA<KittyException>().having((e) => e.message, 'message', 'That window is gone.')),
    );
    fake.answer = (_) => [
      FakeKitty.frame({'ok': false, 'error': 'Something else broke'}),
    ];
    await expectLater(
      fake.kitty().type('kitty-test/9', 'x'),
      throwsA(isA<KittyException>().having((e) => e.message, 'message', 'Something else broke')),
    );
  });

  test('a key for a socket that is not there is refused without asking kitty', () async {
    await expectLater(fake.kitty().close('kitty-gone/1'), throwsA(isA<KittyException>()));
    await expectLater(fake.kitty().close('../kitty-test/1'), throwsA(isA<KittyException>()));
    expect(fake.requests, isEmpty);
  });

  test('a kitty that never answers times out', () async {
    fake.answer = (_) => null;
    final watch = Stopwatch()..start();
    await expectLater(
      fake.kitty(timeout: const Duration(milliseconds: 200)).plainScreen('kitty-test/1'),
      throwsA(isA<KittyException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('lines() strips padding, drops trailing blanks, and keeps the newest lines within historyBytes', () async {
    // 100 lines of 1000 bytes each, then padded and blank lines at the bottom.
    final body = [for (var i = 0; i < 100; i++) '${'$i'.padLeft(3, '0')}${'x' * 997}'];
    final text = [...body, 'prompt \x1b[31m  \x1b[m   ', '   ', '\x1b[m', ''].join('\n');
    fake.answer = (_) => [FakeKitty.ok(text)];
    final lines = await fake.kitty().lines('kitty-test/1', history: true);
    expect(fake.requests.single['payload'], {'match': 'id:1', 'extent': 'all', 'ansi': true});
    expect(lines.last, 'prompt\x1b[31m\x1b[m');
    final bytes = lines.fold(0, (n, l) => n + utf8.encode(l).length + 1);
    expect(bytes, lessThanOrEqualTo(Kitty.historyBytes));
    // 59 full lines plus the prompt fit; the 60th would not.
    expect(lines, hasLength(60));
    expect(lines.first, body[41]);
  });
}
