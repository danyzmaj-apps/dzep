import 'dart:convert';
import 'dart:io';

import 'package:dzep_core/agent.dart';
import 'package:dzep_macos/live_hub.dart';
import 'package:dzep_macos/local_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cli.json ownership', () {
    const ours = '{"port":5000,"token":"mine","pid":1}';
    Future<bool> reclaim(String? text, {bool running = false}) =>
        LocalApi.shouldReclaim(text, ours, answers: (port, token) async => running);

    test('keeps its own file and one naming another running Džep', () async {
      expect(await reclaim(ours), isFalse);
      expect(await reclaim('{"port":6000,"token":"other","pid":2}', running: true), isFalse);
    });

    test('takes it back when missing, unreadable, or naming a Džep that is gone', () async {
      expect(await reclaim(null), isTrue);
      expect(await reclaim('{"port":'), isTrue);
      expect(await reclaim('{"port":"6000"}'), isTrue);
      expect(await reclaim('{"port":6000,"token":"other","pid":2}'), isTrue);
    });

    test('a running Džep writes its address back after another one overwrote it', () async {
      final dir = Directory.systemTemp.createTempSync('dzep-cli');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/cli.json');
      final api = LocalApi(() => null, (_, _) async => false, LiveHub(), file: file);
      await api.start();
      addTearDown(api.stop);
      final written = file.readAsStringSync();
      expect(jsonDecode(written), containsPair('port', api.port));
      expect(file.statSync().modeString(), 'rw-------');
      // A debug build that has quit since.
      file.writeAsStringSync('{"port":1,"token":"dead","pid":999999}');
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(file.readAsStringSync(), written);
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('live sessions over HTTP long polls', () {
    late Directory dir;
    late LiveHub hub;
    late LocalApi api;
    late String token;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('dzep-poll');
      hub = LiveHub();
      api = LocalApi(() => null, (_, _) async => false, hub, file: File('${dir.path}/cli.json'));
      await api.start();
      token = (jsonDecode(api.file.readAsStringSync()) as Map)['token'] as String;
    });

    tearDown(() async {
      await api.stop();
      dir.deleteSync(recursive: true);
    });

    Future<(int, Map<String, dynamic>)> post(Map<String, dynamic> body, {String? auth}) async {
      final client = HttpClient();
      try {
        final req = await client.post('127.0.0.1', api.port!, '/v1/live/http');
        req.headers.set('authorization', 'Bearer ${auth ?? token}');
        req.write(jsonEncode(body));
        final res = await req.close();
        return (res.statusCode, jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>);
      } finally {
        client.close();
      }
    }

    Map<String, dynamic> hello() => {
      't': 'hello',
      'v': 1,
      'agent': 'claude',
      'session': {'id': 's1', 'title': '', 'cwd': '/work/repo', 'model': 'm'},
      'window': 'kitty-1/3',
      'pid': 'x',
      'busy': false,
      'items': const <Object>[],
      'older': false,
      'commands': const <Object>[],
    };

    test("a hello opens a session; the Mac's request waits in the next poll; the reply answers it", () async {
      final (status, opened) = await post({
        'frames': [hello()],
      });
      expect(status, 200);
      final conn = opened['conn'] as String;
      await pumpUntil(() => hub['kitty-1/3'] != null);
      expect(hub['kitty-1/3']!.agent, Agent.claude);

      final poll = post({'conn': conn, 'frames': const <Object>[], 'wait': true});
      final prompted = hub.prompt('kitty-1/3', 'hi');
      final (_, polled) = await poll;
      final frame = (polled['frames'] as List).single as Map<String, dynamic>;
      expect(frame, containsPair('t', 'prompt'));
      expect(frame, containsPair('deliver', 'followUp'));
      expect(frame['files'], isEmpty);
      await post({
        'conn': conn,
        'frames': [
          {'t': 'reply', 'req': frame['req']},
        ],
      });
      await prompted;
    });

    test('frames from an unknown connection get 404, and closing ends the session', () async {
      final (status, _) = await post({'conn': 'nope', 'frames': const <Object>[]});
      expect(status, 404);
      final (_, opened) = await post({
        'frames': [hello()],
      });
      await pumpUntil(() => hub['kitty-1/3'] != null);
      await post({'conn': opened['conn'], 'frames': const <Object>[], 'close': true});
      await pumpUntil(() => hub['kitty-1/3'] == null);
      final (after, _) = await post({'conn': opened['conn'], 'frames': const <Object>[]});
      expect(after, 404);
    });

    test('a wrong token is refused', () async {
      final (status, _) = await post({
        'frames': [hello()],
      }, auth: 'wrong');
      expect(status, 403);
      expect(hub.sessions, isEmpty);
    });
  });
}

/// Waits until [check] holds (requests are served asynchronously).
Future<void> pumpUntil(bool Function() check) async {
  for (var i = 0; i < 100 && !check(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(check(), isTrue);
}
