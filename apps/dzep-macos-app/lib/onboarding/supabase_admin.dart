import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// What went wrong talking to Supabase, worded for the person setting up.
class AdminException implements Exception {
  const AdminException(this.message, {this.status});
  final String message;
  final int? status;

  @override
  String toString() => message;
}

typedef Org = ({String slug, String name});
typedef Project = ({String ref, String name, String status, String region, String org});

/// The Supabase Management API (api.supabase.com), with the access token the
/// user pasted in the setup wizard. Only the calls the setup needs. The token
/// is never stored: it lives as long as this object.
class SupabaseAdmin {
  SupabaseAdmin(this._token, {http.Client? client}) : _http = client ?? http.Client();

  final String _token;
  final http.Client _http;
  static final Uri _base = Uri.parse('https://api.supabase.com');

  Future<List<Map<String, dynamic>>> _list(String path, {Map<String, String>? query}) async {
    final json = await _send('GET', path, query: query);
    return [
      if (json is List)
        for (final item in json)
          if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  Future<Map<String, dynamic>> _map(String method, String path, {Object? body}) async {
    final json = await _send(method, path, body: body);
    if (json is! Map) throw const AdminException('Supabase sent an unexpected answer.');
    return Map<String, dynamic>.from(json);
  }

  void close() => _http.close();

  Map<String, String> get _headers => {'authorization': 'Bearer $_token', 'content-type': 'application/json'};

  Future<Object?> _send(String method, String path, {Object? body, Map<String, String>? query}) async {
    final req = http.Request(method, _base.replace(path: path, queryParameters: query))..headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 60)));
    } on TimeoutException {
      throw const AdminException('Supabase took too long to answer. Try again.');
    } on Object {
      throw const AdminException("Couldn't reach Supabase. Check your connection.");
    }
    return _decode(res);
  }

  static Object? _decode(http.Response res) {
    final text = utf8.decode(res.bodyBytes);
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      json = null;
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return json;
    final detail = json is Map ? (json['message'] ?? json['msg'] ?? json['error'] ?? '').toString() : text.trim();
    throw AdminException(switch (res.statusCode) {
      401 => 'Supabase refused that access token. Create a new one and paste it again.',
      403 => "That access token isn't allowed to do this${detail.isEmpty ? '' : ': $detail'}",
      429 => 'Supabase is rate-limiting requests. Wait a minute, then retry.',
      _ => detail.isEmpty ? 'Supabase answered with an error (${res.statusCode}).' : detail,
    }, status: res.statusCode);
  }

  static Project _project(Map<String, dynamic> p) => (
    ref: p['id'] as String? ?? p['ref'] as String,
    name: p['name'] as String? ?? '',
    status: p['status'] as String? ?? '',
    region: p['region'] as String? ?? '',
    org: p['organization_slug'] as String? ?? p['organization_id'] as String? ?? '',
  );

  Future<List<Org>> organizations() async => [
    for (final o in await _list('/v1/organizations'))
      (slug: o['slug'] as String? ?? o['id'] as String, name: o['name'] as String? ?? ''),
  ];

  Future<List<Project>> projects() async => [for (final p in await _list('/v1/projects')) _project(p)];

  Future<Project> project(String ref) async => _project(await _map('GET', '/v1/projects/$ref'));

  /// A new project; it takes a minute or two to come up ([waitUntilReady]).
  Future<Project> createProject({
    required String org,
    required String name,
    required String region,
    required String dbPassword,
  }) async {
    try {
      return _project(
        await _map(
          'POST',
          '/v1/projects',
          body: {
            'organization_slug': org,
            'name': name,
            'db_pass': dbPassword,
            'region_selection': {'type': 'specific', 'code': region},
          },
        ),
      );
    } on AdminException catch (e) {
      final m = e.message.toLowerCase();
      // 429 is "rate-limiting", not the plan.
      if (e.status != 429 && (m.contains('limit') || m.contains('maximum'))) {
        throw AdminException(
          'Your Supabase account already has the two active projects the free plan allows. Pause or delete one '
          "you don't need (open it at supabase.com/dashboard, then Project Settings → General), then press "
          'Create project again. Or choose "Use an existing project".',
          status: e.status,
        );
      }
      rethrow;
    }
  }

  /// Polls until the project is up, or fails after [timeout]. False when
  /// [stop] completes first.
  Future<bool> waitUntilReady(String ref, {Duration timeout = const Duration(minutes: 6), Future<void>? stop}) async {
    final end = DateTime.now().add(timeout);
    var stopped = false;
    unawaited(stop?.then((_) => stopped = true));
    while (!stopped) {
      final status = (await project(ref)).status;
      if (stopped) break;
      if (status == 'ACTIVE_HEALTHY') return true;
      if (status.contains('FAILED') || status == 'INACTIVE' || status == 'PAUSED') {
        throw AdminException('The project is $status. Restore it in the Supabase dashboard, then retry.');
      }
      if (!DateTime.now().isBefore(end)) {
        throw const AdminException('The project is still starting. Give it another minute, then continue.');
      }
      await Future.any([Future<void>.delayed(const Duration(seconds: 5)), ?stop]);
    }
    return false;
  }

  /// Runs SQL as the database owner; the rows of the last statement.
  Future<List<Map<String, dynamic>>> query(String ref, String sql) async {
    final rows = await _send('POST', '/v1/projects/$ref/database/query', body: {'query': sql});
    return [
      if (rows is List)
        for (final r in rows) Map<String, dynamic>.from(r as Map),
    ];
  }

  Future<Map<String, dynamic>> authConfig(String ref) => _map('GET', '/v1/projects/$ref/config/auth');

  Future<void> updateAuthConfig(String ref, Map<String, Object?> changes) =>
      _send('PATCH', '/v1/projects/$ref/config/auth', body: changes);

  Future<void> setSecrets(String ref, Map<String, String> secrets) => _send(
    'POST',
    '/v1/projects/$ref/secrets',
    body: [
      for (final MapEntry(:key, :value) in secrets.entries) {'name': key, 'value': value},
    ],
  );

  /// The key apps use: the publishable one, else the legacy anon key.
  Future<String> publishableKey(String ref) async {
    final keys = await _list('/v1/projects/$ref/api-keys', query: {'reveal': 'false'});
    String? find(bool Function(Map<String, dynamic>) test) => keys.where(test).firstOrNull?['api_key'] as String?;
    final key = find((k) => k['type'] == 'publishable') ?? find((k) => k['name'] == 'anon');
    if (key == null) throw const AdminException('The project has no publishable key. Create one under API Keys.');
    return key;
  }

  /// Deploys one edge function from its source; Supabase bundles it.
  Future<void> deployFunction(String ref, String slug, String source, {required bool verifyJwt}) async {
    final req =
        http.MultipartRequest(
            'POST',
            _base.replace(path: '/v1/projects/$ref/functions/deploy', queryParameters: {'slug': slug}),
          )
          ..headers['authorization'] = 'Bearer $_token'
          ..fields['metadata'] = jsonEncode({'entrypoint_path': 'index.ts', 'name': slug, 'verify_jwt': verifyJwt})
          ..files.add(http.MultipartFile.fromString('file', source, filename: 'index.ts'));
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(minutes: 2)));
    } on TimeoutException {
      throw AdminException('Deploying $slug took too long. Retry.');
    } on Object {
      throw const AdminException("Couldn't reach Supabase. Check your connection.");
    }
    _decode(res);
  }
}
