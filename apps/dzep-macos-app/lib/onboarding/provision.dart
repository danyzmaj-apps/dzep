import 'package:dzep_core/backend.dart';
import 'package:dzep_macos/onboarding/supabase_admin.dart';
import 'package:flutter/services.dart';

/// One migration: `supabase/migrations/<version>_<name>.sql`.
typedef Migration = ({String version, String name, String sql});

/// The backend the app ships with (the pubspec bundles supabase/ as assets),
/// so a downloaded app can set up a server without the repo or the CLI.
abstract interface class BackendSource {
  /// Oldest first.
  Future<List<Migration>> migrations();
  Future<String> function(String slug);
}

class AssetBackendSource implements BackendSource {
  const AssetBackendSource();

  @override
  Future<List<Migration>> migrations() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final paths =
        manifest.listAssets().where((p) => p.startsWith('supabase/migrations/') && p.endsWith('.sql')).toList()..sort();
    return [for (final p in paths) migrationFromFile(p, await rootBundle.loadString(p))];
  }

  @override
  Future<String> function(String slug) => rootBundle.loadString('supabase/functions/$slug/index.ts');
}

/// `…/20261006140000_ideas.sql` → version `20261006140000`, name `ideas`.
Migration migrationFromFile(String path, String sql) {
  final file = path.split('/').last.replaceFirst(RegExp(r'\.sql$'), '');
  final cut = file.indexOf('_');
  return (version: cut < 0 ? file : file.substring(0, cut), name: cut < 0 ? '' : file.substring(cut + 1), sql: sql);
}

/// The OpenAI-compatible API the Ask feature uses; null skips it.
typedef AiSettings = ({String baseUrl, String model, String key});

enum ProvisionStep {
  database('Database'),
  signIn('GitHub sign-in'),
  functions('Server functions'),
  ai('AI for quick questions'),
  keys('Connection key');

  const ProvisionStep(this.label);
  final String label;
}

/// Sets up (or updates) a Džep server on a Supabase project, the same thing
/// tool/setup-backend.sh does with the CLI. Every step can run again: applied
/// migrations are skipped, the rest is overwritten with the same values.
class Provisioner {
  Provisioner({required this.admin, required this.ref, this.source = const AssetBackendSource()});

  final SupabaseAdmin admin;
  final String ref;
  final BackendSource source;

  static const redirect = 'dzep://login-callback';
  static const hook = 'pg-functions://postgres/public/before_user_created';

  String get url => 'https://$ref.supabase.co';

  /// GitHub's "Authorization callback URL" for this project.
  String get githubCallback => '$url/auth/v1/callback';

  /// Looks at a project before Džep goes on it. `stop`: why it can't (it has
  /// accounts, so the private-server hook would turn the owner away, or
  /// tables and the like the migrations need to create). `replaces`: the
  /// settings of its own that Džep would overwrite. Both null for a fresh
  /// project, or one Džep is already on (an update).
  Future<({String? stop, String? replaces})> inspect() async {
    final migrations = await source.migrations();
    String list(Iterable<String> names) =>
        'array[${names.map((n) => "'${n.replaceAll("'", "''")}'").join(',')}]::text[]';
    final recorded = await admin.query(
      ref,
      "select to_regclass('supabase_migrations.schema_migrations') is not null as recorded",
    );
    if (recorded.firstOrNull?['recorded'] == true) {
      final ours = await admin.query(
        ref,
        'select exists (select 1 from supabase_migrations.schema_migrations '
        'where version = any(${list(migrations.map((m) => m.version))})) as ours',
      );
      if (ours.firstOrNull?['ours'] == true) return (stop: null, replaces: null);
    }

    Set<String> named(String pattern) => {
      for (final m in migrations)
        for (final hit in RegExp(pattern, caseSensitive: false).allMatches(m.sql)) hit.group(1)!,
    };
    final relations = named(
      r'create\s+(?:table|view|(?:unique\s+)?index)\s+(?:if\s+not\s+exists\s+)?(?:public\.)?(\w+)(?![\w.])',
    );
    final functions = named(r'create\s+function\s+public\.(\w+)');
    final buckets = named(r"insert\s+into\s+storage\.buckets[^;]*?values\s*\(\s*'([^']+)'");
    final found = (await admin.query(ref, '''
select
  (select count(*) from auth.users)::int as users,
  concat_ws(', ',
    (select string_agg(relname, ', ' order by relname) from pg_class
      where relnamespace = 'public'::regnamespace and relname = any(${list(relations)})),
    (select string_agg(distinct proname || '()', ', ') from pg_proc
      where pronamespace = 'public'::regnamespace and proname = any(${list(functions)})),
    (select string_agg('storage bucket ' || id, ', ' order by id) from storage.buckets where id = any(${list(buckets)}))
  ) as taken''')).firstOrNull;
    final users = (found?['users'] as num?) ?? 0;
    final taken = found?['taken'] as String? ?? '';
    if (users > 0) {
      return (
        stop:
            'This project already has accounts. A Džep server lets in only the first account to sign in, so '
            'yours would be turned away. Create a new project for Džep instead.',
        replaces: null,
      );
    }
    if (taken.isNotEmpty) {
      return (
        stop:
            'This project already has $taken, which Džep needs to make itself. Create a new project for Džep instead.',
        replaces: null,
      );
    }

    final auth = await admin.authConfig(ref);
    final site = auth['site_url'] as String? ?? '';
    final hookUri = auth['hook_before_user_created_uri'] as String? ?? '';
    final replaces = [
      if (site.isNotEmpty && site != redirect && site != 'http://localhost:3000') 'Site URL ($site)',
      if (auth['hook_before_user_created_enabled'] == true && hookUri != hook) 'before-user-created hook',
      if (auth['external_github_enabled'] == true) 'GitHub sign-in app',
    ];
    return (
      stop: null,
      replaces: replaces.isEmpty
          ? null
          : "Džep sets sign-in up its own way and would replace this project's ${replaces.join(', ')}. "
                'Anything that uses them now stops working.',
    );
  }

  /// Applies the migrations the project hasn't had yet, each in its own
  /// transaction, recording them where the Supabase CLI does (so a later
  /// `supabase db push` agrees). Returns how many were applied.
  Future<int> migrate() async {
    await admin.query(
      ref,
      '''
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);''',
    );
    final applied = {
      for (final r in await admin.query(ref, 'select version from supabase_migrations.schema_migrations'))
        r['version'] as String,
    };
    var count = 0;
    for (final m in await source.migrations()) {
      if (applied.contains(m.version)) continue;
      await admin.query(
        ref,
        'begin;\n${m.sql}\n;\n'
        'insert into supabase_migrations.schema_migrations (version, name) '
        "values ('${m.version}', '${m.name.replaceAll("'", "''")}');\ncommit;",
      );
      count++;
    }
    return count;
  }

  /// GitHub as the only way in, the app's redirect, and the private-server
  /// hook (the first account owns the server).
  Future<void> configureSignIn({required String githubClientId, required String githubSecret}) async {
    final current = await admin.authConfig(ref);
    final allowed = {
      for (final u in (current['uri_allow_list'] as String? ?? '').split(','))
        if (u.trim().isNotEmpty) u.trim(),
      redirect,
    };
    await admin.updateAuthConfig(ref, {
      'site_url': redirect,
      'uri_allow_list': allowed.join(','),
      'external_github_enabled': true,
      'external_github_client_id': githubClientId.trim(),
      'external_github_secret': githubSecret.trim(),
      'hook_before_user_created_enabled': true,
      'hook_before_user_created_uri': hook,
      // functions/pair swaps a phone's code for a magic-link token used at once.
      'mailer_otp_exp': 600,
    });
  }

  Future<void> deployFunctions() async {
    // relay is the publisher's alone (tool/deploy-relay.sh): never on a user's server.
    for (final slug in ['ask', 'device', 'pair', 'push']) {
      // All check the caller themselves (a user token, a device token, the scheduler's secret).
      await admin.deployFunction(ref, slug, await source.function(slug), verifyJwt: false);
    }
  }

  Future<void> setAi(AiSettings ai) => admin.setSecrets(ref, {
    'AI_BASE_URL': ai.baseUrl.trim(),
    'AI_MODEL': ai.model.trim(),
    'AI_API_KEY': ai.key.trim(),
  });

  Future<Backend> backend() async => Backend(url: url, key: await admin.publishableKey(ref));

  /// Everything, in order; [onStep] hears each step as it starts. Skips the
  /// steps in [done] (a retry after a failure picks up where it stopped).
  Future<Backend> run({
    required String githubClientId,
    required String githubSecret,
    required AiSettings? ai,
    void Function(ProvisionStep step)? onStep,
    Set<ProvisionStep> done = const {},
  }) async {
    Future<void> step(ProvisionStep s, Future<void> Function() work) async {
      if (done.contains(s)) return;
      onStep?.call(s);
      await work();
    }

    await step(ProvisionStep.database, migrate);
    await step(ProvisionStep.signIn, () => configureSignIn(githubClientId: githubClientId, githubSecret: githubSecret));
    await step(ProvisionStep.functions, deployFunctions);
    if (ai != null) await step(ProvisionStep.ai, () => setAi(ai));
    onStep?.call(ProvisionStep.keys);
    return await backend();
  }
}
