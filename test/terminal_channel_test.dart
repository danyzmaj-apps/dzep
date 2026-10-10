import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dzep/terminal_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A Realtime server on loopback, speaking Phoenix's 2.0.0 text frames
/// (`[join_ref, ref, topic, event, payload]`), that answers each join of the
/// terminal topic with the next of [joinReplies] ('ok' once they run out).
class _FakeRealtime {
  _FakeRealtime(this.joinReplies);

  final List<String> joinReplies;
  late final HttpServer _server;
  late WebSocket _ws;
  String? _joinRef;

  /// Joins of the terminal topic so far, as they arrive.
  final joins = StreamController<int>.broadcast();
  int joinCount = 0;

  static const topic = 'realtime:terminal:u1';

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final ws = _ws = await WebSocketTransformer.upgrade(req);
      ws.listen((frame) {
        final m = jsonDecode(frame as String) as List<dynamic>;
        final (joinRef, ref, topic, event) = (m[0], m[1], m[2] as String, m[3] as String);
        if (topic == 'phoenix' && event == 'heartbeat') {
          ws.add(
            jsonEncode([
              null,
              ref,
              'phoenix',
              'phx_reply',
              {'status': 'ok', 'response': <String, Object>{}},
            ]),
          );
        } else if (topic == _FakeRealtime.topic && event == 'phx_join') {
          final status = joinCount < joinReplies.length ? joinReplies[joinCount] : 'ok';
          joinCount++;
          _joinRef = joinRef as String?;
          ws.add(
            jsonEncode([
              joinRef,
              ref,
              topic,
              'phx_reply',
              {
                'status': status,
                'response': status == 'ok' ? <String, Object>{} : {'reason': 'Unauthorized'},
              },
            ]),
          );
          joins.add(joinCount);
        } else if (event == 'phx_leave') {
          ws.add(
            jsonEncode([
              joinRef,
              ref,
              topic,
              'phx_reply',
              {'status': 'ok', 'response': <String, Object>{}},
            ]),
          );
        }
      });
    });
  }

  /// The server ends the channel, as Realtime does when the token it joined
  /// with expires.
  void closeChannel() => _ws.add(jsonEncode([_joinRef, null, topic, 'phx_close', <String, Object>{}]));

  /// As a Dart client sends one: the payload's fields next to `type` and `event`.
  void broadcast(String event, Map<String, dynamic> payload) => _ws.add(
    jsonEncode([
      null,
      null,
      topic,
      'broadcast',
      {'type': 'broadcast', 'event': event, ...payload},
    ]),
  );

  Future<void> stop() async {
    await joins.close();
    await _server.close(force: true);
  }
}

void main() {
  late _FakeRealtime server;
  late SupabaseClient client;
  late TerminalChannel channel;
  late List<bool> states;
  late List<Map<String, dynamic>> received;

  Future<void> setUpServer(List<String> joinReplies) async {
    server = _FakeRealtime(joinReplies);
    await server.start();
    client = SupabaseClient('http://127.0.0.1:${server.port}', 'anon');
    states = [];
    received = [];
    channel = TerminalChannel(
      client,
      'u1',
      {'state': received.add},
      name: 'test',
      onJoined: ({required joined}) => states.add(joined),
    );
  }

  Future<void> joined(int count) =>
      server.joins.stream.firstWhere((n) => n >= count).timeout(const Duration(seconds: 5));

  Future<void> until(bool Function() check) async {
    for (var i = 0; i < 300 && !check(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(check(), isTrue);
  }

  tearDown(() async {
    await channel.close();
    await client.dispose();
    await server.stop();
  });

  test('a channel the server closes is joined again, and broadcasts reach it after', () async {
    await setUpServer(const []);
    channel.open();
    await joined(1);
    await until(() => channel.joined);

    server.closeChannel();
    await until(() => !channel.joined);
    await joined(2);
    await until(() => channel.joined);
    expect(states, [true, false, true]);

    server.broadcast('state', {'windows': 3});
    await until(() => received.isNotEmpty);
    expect(received.single['windows'], 3);
  });

  test('a refused join (an expired token) is tried again until it is let in', () async {
    await setUpServer(const ['error', 'error']);
    channel.open();
    await joined(3);
    await until(() => channel.joined);
    expect(states, [true]);
  });

  test('after close nothing joins again', () async {
    await setUpServer(const ['error']);
    channel.open();
    await joined(1);
    await channel.close();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(server.joinCount, 1);
    expect(channel.joined, isFalse);
  });
}
