import 'dart:convert';

import 'package:dzep_core/backend.dart';
import 'package:dzep_core/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

/// A session whose device cleanup can't reach the server (offline, or an
/// account deleted a moment ago).
class _OfflineSession extends Session {
  _OfflineSession(this._client) : super('iPhone');
  final SupabaseClient _client;

  @override
  SupabaseClient get client => _client;

  @override
  Future<void> onSigningOut({required bool accountDeleted}) async =>
      throw const FunctionsHttpException(status: 401, details: {'error': 'Sign in first'});
}

/// A signed-out phone that records which setup links it acts on.
class _LinkSession extends Session {
  _LinkSession() : super('iPhone');
  final connected = <Uri>[];

  @override
  Future<void> connectLink(Uri uri) async => connected.add(uri);
}

String _jwt(Map<String, Object> claims) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.c2ln';
}

void main() {
  test('signing out drops the saved session even when the cleanup before it fails', () async {
    final requests = <String>[];
    final client = SupabaseClient(
      'http://localhost:54321',
      'publishable',
      httpClient: MockClient((req) async {
        requests.add(req.url.path);
        throw http.ClientException('offline', req.url);
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
    await client.auth.recoverSession(
      jsonEncode({
        'access_token': _jwt({'sub': 'u1', 'exp': exp}),
        'refresh_token': 'r',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': {
          'id': 'u1',
          'aud': 'authenticated',
          'created_at': '2026-01-01T00:00:00Z',
          'app_metadata': <String, Object>{},
        },
      }),
    );
    expect(client.auth.currentSession, isNotNull);

    final session = _OfflineSession(client);
    await session.signOut();

    expect(client.auth.currentSession, isNull, reason: 'a relaunch would sign straight back in');
    expect(requests, contains('/auth/v1/logout'));
    expect(session.signedOutReason, 'You signed out.');
  });

  group('a setup link opened from outside the app', () {
    const mine = Backend(url: 'https://mine.supabase.co', key: 'k');
    const theirs = Backend(url: 'https://theirs.supabase.co', key: 'k');

    test('connects a signed-out device to another server only once the person says so', () async {
      final session = _LinkSession();
      final link = theirs.linkWithCode('ABCD-1234');
      session.openedLink(link, mine);
      expect(session.connected, isEmpty);
      expect(session.linkToConfirm, link);
      await session.answerLink(connect: true);
      expect(session.connected, [link]);
      expect(session.linkToConfirm, isNull);
    });

    test('is dropped when the person says no, and asks on a device set up nowhere yet', () async {
      final session = _LinkSession()..openedLink(theirs.linkWithCode('ABCD-1234'), null);
      expect(session.linkToConfirm, isNotNull);
      await session.answerLink(connect: false);
      expect(session.connected, isEmpty);
      expect(session.linkToConfirm, isNull);
    });

    test("goes ahead for the device's own server: the Mac's code scanned with the camera", () {
      final session = _LinkSession();
      final link = mine.linkWithCode('ABCD-1234');
      session.openedLink(link, mine);
      expect(session.connected, [link]);
      expect(session.linkToConfirm, isNull);
    });
  });
}
