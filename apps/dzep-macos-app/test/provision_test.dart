import 'dart:convert';

import 'package:dzep_macos/onboarding/provision.dart';
import 'package:dzep_macos/onboarding/supabase_admin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A Management API that remembers what was applied, like a real project.
class FakeApi {
  final applied = <String>{'20260101000000'};
  final queries = <String>[];
  Map<String, dynamic> auth = {'uri_allow_list': 'https://example.com', 'site_url': 'http://localhost:3000'};
  final deployed = <String, Map<String, dynamic>>{};
  final secrets = <String, String>{};

  late final client = MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/database/query')) {
      final sql = (jsonDecode(req.body) as Map)['query'] as String;
      queries.add(sql);
      if (sql.startsWith('select version')) {
        return http.Response(
          jsonEncode([
            for (final v in applied) {'version': v},
          ]),
          201,
        );
      }
      final m = RegExp(r"values \('(\d+)'").firstMatch(sql);
      if (m != null) applied.add(m.group(1)!);
      return http.Response('[]', 201);
    }
    if (path.endsWith('/config/auth')) {
      if (req.method == 'PATCH') auth = {...auth, ...jsonDecode(req.body) as Map<String, dynamic>};
      return http.Response(jsonEncode(auth), 200);
    }
    if (path.endsWith('/secrets')) {
      for (final s in jsonDecode(req.body) as List) {
        secrets[(s as Map)['name'] as String] = s['value'] as String;
      }
      return http.Response('', 201);
    }
    if (path.endsWith('/api-keys')) {
      return http.Response(
        jsonEncode([
          {'name': 'anon', 'type': 'legacy', 'api_key': 'eyJ.anon.key'},
          {'name': 'default', 'type': 'publishable', 'api_key': 'sb_publishable_abc'},
        ]),
        200,
      );
    }
    return http.Response('not found', 404);
  });

  /// Function deploys are multipart; MockClient sees the encoded body.
  late final streaming = MockClient.streaming((req, body) async {
    final bytes = await body.toBytes();
    if (req.url.path.endsWith('/functions/deploy')) {
      final text = utf8.decode(bytes, allowMalformed: true);
      final meta = RegExp(r'\{"entrypoint_path".*?\}').firstMatch(text)!.group(0)!;
      deployed[req.url.queryParameters['slug']!] = jsonDecode(meta) as Map<String, dynamic>;
      return http.StreamedResponse(Stream.value(utf8.encode('{}')), 201);
    }
    final res = await client.send(http.Request(req.method, req.url)..bodyBytes = bytes);
    return res;
  });
}

class FakeSource implements BackendSource {
  @override
  Future<List<Migration>> migrations() async => [
    migrationFromFile('supabase/migrations/20260101000000_first.sql', 'create table a ();'),
    migrationFromFile('supabase/migrations/20260102000000_second_one.sql', "insert into a values ('it''s');"),
    migrationFromFile('supabase/migrations/20260103000000_third.sql', 'create table c ();'),
  ];

  @override
  Future<String> function(String slug) async => '// $slug';
}

void main() {
  test('migration files read as version and name', () {
    final m = migrationFromFile('supabase/migrations/20261012090000_notes.sql', 'sql');
    expect((m.version, m.name), ('20261012090000', 'notes'));
  });

  test('a fresh run applies only missing migrations, in order, and records them', () async {
    final api = FakeApi();
    final p = Provisioner(
      admin: SupabaseAdmin('sbp_x', client: api.streaming),
      ref: 'abc',
      source: FakeSource(),
    );

    expect(await p.migrate(), 2);
    final applying = api.queries.where((q) => q.startsWith('begin;')).toList();
    expect(applying, hasLength(2));
    expect(applying[0], contains("values ('20260102000000', 'second_one')"));
    expect(applying[0], contains("insert into a values ('it''s');"));
    expect(applying[1], contains('20260103000000'));
    expect(applying.every((q) => q.trimRight().endsWith('commit;')), isTrue);

    // Running again changes nothing.
    expect(await p.migrate(), 0);
  });

  test('the whole setup configures sign-in, functions, AI and returns the publishable key', () async {
    final api = FakeApi();
    final p = Provisioner(
      admin: SupabaseAdmin('sbp_x', client: api.streaming),
      ref: 'abc',
      source: FakeSource(),
    );
    final seen = <ProvisionStep>[];

    final backend = await p.run(
      githubClientId: ' Iv1.id ',
      githubSecret: 'secret',
      ai: (baseUrl: 'https://api.deepseek.com', model: 'deepseek-flash', key: 'sk-1'),
      onStep: seen.add,
    );

    expect(seen, ProvisionStep.values);
    expect(backend.url, 'https://abc.supabase.co');
    expect(backend.key, 'sb_publishable_abc');
    expect(api.auth['external_github_enabled'], isTrue);
    expect(api.auth['external_github_client_id'], 'Iv1.id');
    expect(api.auth['site_url'], 'dzep://login-callback');
    // Keeps the redirects that were already allowed.
    expect(api.auth['uri_allow_list'], 'https://example.com,dzep://login-callback');
    expect(api.auth['hook_before_user_created_enabled'], isTrue);
    expect(api.auth['external_email_enabled'], isFalse);
    expect(api.deployed.keys, {'ask', 'device', 'pair', 'push'});
    expect(api.deployed.values.every((m) => m['verify_jwt'] == false), isTrue);
    expect(api.secrets, {
      'AI_BASE_URL': 'https://api.deepseek.com',
      'AI_MODEL': 'deepseek-flash',
      'AI_API_KEY': 'sk-1',
    });
  });

  test('a retry skips the steps already done; no AI skips the secrets', () async {
    final api = FakeApi();
    final p = Provisioner(
      admin: SupabaseAdmin('sbp_x', client: api.streaming),
      ref: 'abc',
      source: FakeSource(),
    );
    final seen = <ProvisionStep>[];

    await p.run(
      githubClientId: 'id',
      githubSecret: 's',
      ai: null,
      onStep: seen.add,
      done: {ProvisionStep.database, ProvisionStep.signIn},
    );

    expect(seen, [ProvisionStep.functions, ProvisionStep.keys]);
    expect(api.queries, isEmpty);
    expect(api.secrets, isEmpty);
  });

  test('API errors read as something a person can act on', () async {
    final admin = SupabaseAdmin('sbp_bad', client: MockClient((_) async => http.Response('{"message":"x"}', 401)));
    expect(
      admin.projects,
      throwsA(isA<AdminException>().having((e) => e.message, 'message', contains('access token'))),
    );
  });
}
