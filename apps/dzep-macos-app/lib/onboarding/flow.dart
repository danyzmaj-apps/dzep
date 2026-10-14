import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dzep_core/backend.dart';
import 'package:dzep_macos/onboarding/provision.dart';
import 'package:dzep_macos/onboarding/supabase_admin.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

enum WizardStep { welcome, token, project, github, ai, setup }

/// An AI provider the wizard knows; "Other" takes a typed URL and model.
typedef AiPreset = ({String name, String baseUrl, String model, String keysUrl});

const aiPresets = <AiPreset>[
  (
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-flash',
    keysUrl: 'https://platform.deepseek.com/api_keys',
  ),
  (
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    model: 'gpt-5-mini',
    keysUrl: 'https://platform.openai.com/api-keys',
  ),
  (
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    model: 'openai/gpt-5-mini',
    keysUrl: 'https://openrouter.ai/keys',
  ),
];

/// Supabase regions the wizard offers, nearest-first guesses by time zone.
const regions = <(String, String)>[
  ('eu-central-1', 'Frankfurt'),
  ('eu-west-2', 'London'),
  ('eu-west-1', 'Ireland'),
  ('us-east-1', 'N. Virginia'),
  ('us-west-1', 'N. California'),
  ('ca-central-1', 'Canada'),
  ('sa-east-1', 'São Paulo'),
  ('ap-south-1', 'Mumbai'),
  ('ap-southeast-1', 'Singapore'),
  ('ap-northeast-1', 'Tokyo'),
  ('ap-southeast-2', 'Sydney'),
];

String guessRegion(Duration utcOffset) {
  final h = utcOffset.inHours;
  if (h <= -7) return 'us-west-1';
  if (h <= -3) return 'us-east-1';
  if (h <= 4) return 'eu-central-1';
  if (h <= 6) return 'ap-south-1';
  if (h <= 8) return 'ap-southeast-1';
  if (h <= 9) return 'ap-northeast-1';
  return 'ap-southeast-2';
}

/// Asks GitHub to trade a made-up code with these OAuth app credentials:
/// GitHub names a wrong client id, secret or callback URL before it gets to
/// the code. Null when they look right, or when GitHub can't be asked (the
/// setup goes on; the sign-in itself would tell).
Future<String?> checkGithubApp(
  http.Client client, {
  required String clientId,
  required String secret,
  required String callback,
}) async {
  try {
    final res = await client
        .post(
          Uri.https('github.com', '/login/oauth/access_token'),
          headers: {'accept': 'application/json'},
          body: {'client_id': clientId, 'client_secret': secret, 'code': 'dzep-setup-check', 'redirect_uri': callback},
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 404) return "GitHub doesn't know that Client ID. Copy it again from the OAuth app's page.";
    final json = jsonDecode(res.body);
    return switch (json is Map ? json['error'] : null) {
      'incorrect_client_credentials' =>
        "GitHub didn't accept that client secret. Generate a new one on the OAuth app's page and paste it.",
      'redirect_uri_mismatch' => "The OAuth app's Authorization callback URL must be $callback. Fix it on GitHub.",
      _ => null,
    };
  } on Object {
    return null;
  }
}

/// The setup wizard: Supabase access → a project → GitHub sign-in → AI →
/// [Provisioner] does the rest. The access token and the secrets only live
/// in this object; nothing here is saved.
class SetupFlow extends ChangeNotifier {
  SetupFlow({
    SupabaseAdmin Function(String token)? admin,
    this.source = const AssetBackendSource(),
    http.Client? web,
    Future<String?> Function(Backend backend)? check,
    this.startTimeout = const Duration(minutes: 6),
    this.checkPause = const Duration(seconds: 3),
  }) : _newAdmin = admin ?? SupabaseAdmin.new,
       _web = web ?? http.Client(),
       _check = check ?? ((b) => b.check());

  final SupabaseAdmin Function(String token) _newAdmin;
  final BackendSource source;

  /// GitHub, for [checkGithubApp].
  final http.Client _web;
  final Future<String?> Function(Backend backend) _check;

  /// How long the wizard waits for a new project before it stops (Continue
  /// waits again).
  final Duration startTimeout;

  /// Between checks of the finished server: its auth service takes a few
  /// seconds to pick up new settings.
  final Duration checkPause;

  WizardStep step = WizardStep.welcome;
  bool busy = false;
  String? error;

  // ---- Supabase access
  SupabaseAdmin? _admin;
  List<Org> orgs = const [];
  List<Project> projects = const [];

  static const _usable = {'ACTIVE_HEALTHY', 'COMING_UP'};

  /// Projects that can hold a Džep server: running ones, and ones still
  /// starting (the wizard waits for them).
  List<Project> get usableProjects => projects.where((p) => _usable.contains(p.status)).toList();

  // ---- project choice
  bool createNew = true;
  String newName = 'dzep';
  String? org;
  String region = guessRegion(DateTime.now().timeZoneOffset);
  String? existingRef;
  String? ref;

  /// Projects this wizard created: fresh, nothing to look at first.
  final Set<String> _made = {};

  /// While a new project starts.
  String? waiting;
  Completer<void>? _stopWaiting;

  /// What Džep would replace on the chosen existing project; the next
  /// Continue takes it anyway.
  String? get caution => !createNew && _caution?.ref == existingRef ? _caution?.text : null;
  ({String ref, String text})? _caution;

  // ---- GitHub
  String githubId = '';
  String githubSecret = '';

  // ---- AI
  AiPreset? aiPreset = aiPresets.first;
  String aiBaseUrl = aiPresets.first.baseUrl;
  String aiModel = aiPresets.first.model;
  String aiKey = '';

  /// False after "Skip AI for now", for Retry too.
  bool withAi = true;
  bool get usesAi => withAi && aiKey.trim().isNotEmpty;

  // ---- setup
  final Set<ProvisionStep> done = {};

  /// What each step in [done] was done with: a step whose inputs changed
  /// since (Back and an edit, another project) runs again.
  final Map<ProvisionStep, Object?> _doneWith = {};
  ProvisionStep? current;
  Backend? backend;

  /// Set up and checked: what is left is connecting.
  bool ready = false;

  String get githubCallback => 'https://$ref.supabase.co/auth/v1/callback';

  /// Leaving the project step stops waiting for a new project; it stays
  /// picked, so coming back waits for the same one.
  void go(WizardStep s) {
    _stopWaiting?.complete();
    _stopWaiting = null;
    step = s;
    error = null;
    notifyListeners();
  }

  void update(VoidCallback change) {
    change();
    error = null;
    notifyListeners();
  }

  Future<void> _busy(Future<void> Function() work) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await work();
    } on AdminException catch (e) {
      error = e.message;
    } on Object catch (e) {
      error = 'Something went wrong: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Checks the token by listing what it can reach.
  Future<void> submitToken(String token) => _busy(() async {
    final t = token.trim();
    if (!t.startsWith('sbp_')) {
      throw const AdminException('Paste a personal access token: it starts with sbp_.');
    }
    final admin = _newAdmin(t);
    final (o, p) = (await admin.organizations(), await admin.projects());
    if (o.isEmpty) throw const AdminException('This account has no organization yet. Create one at supabase.com.');
    _admin?.close();
    _admin = admin;
    orgs = o;
    projects = p;
    if (!o.any((x) => x.slug == org)) org = o.first.slug;
    if (!usableProjects.any((x) => x.ref == existingRef)) existingRef = null;
    // An existing project called dzep is most likely a previous attempt.
    final named = usableProjects.where((x) => x.name == 'dzep').firstOrNull;
    if (existingRef == null && named != null) existingRef = named.ref;
    if (existingRef != null) createNew = false;
    step = WizardStep.project;
  });

  /// Creates the project (once: a retry, or coming back, waits for the same
  /// one) or takes the chosen one, after it's up and checked.
  Future<void> submitProject() => _busy(() async {
    final admin = _admin!;
    if (createNew) {
      final name = newName.trim().isEmpty ? 'dzep' : newName.trim();
      final p = await admin.createProject(org: org!, name: name, region: region, dbPassword: _password());
      _made.add(p.ref);
      projects = [
        ...projects,
        (ref: p.ref, name: p.name.isEmpty ? name : p.name, status: 'COMING_UP', region: p.region, org: p.org),
      ];
      createNew = false;
      existingRef = p.ref;
    }
    final r = existingRef;
    if (r == null) throw const AdminException('Pick a project.');
    if (projects.where((x) => x.ref == r).firstOrNull?.status != 'ACTIVE_HEALTHY') {
      final stop = _stopWaiting = Completer<void>();
      waiting = 'Starting your project. This takes a minute or two…';
      notifyListeners();
      try {
        final up = await admin.waitUntilReady(r, timeout: startTimeout, stop: stop.future);
        if (!up || stop.isCompleted) return;
      } finally {
        if (_stopWaiting == stop) _stopWaiting = null;
        waiting = null;
      }
      projects = [
        for (final x in projects)
          if (x.ref == r) (ref: x.ref, name: x.name, status: 'ACTIVE_HEALTHY', region: x.region, org: x.org) else x,
      ];
    }
    if (!_made.contains(r) && _caution?.ref != r) {
      final found = await Provisioner(admin: admin, ref: r, source: source).inspect();
      if (found.stop case final stop?) throw AdminException(stop);
      if (found.replaces case final text?) {
        _caution = (ref: r, text: text);
        return;
      }
    }
    ref = r;
    step = WizardStep.github;
  });

  /// Moves on once GitHub takes the credentials.
  Future<void> submitGithub() => _busy(() async {
    if (githubId.trim().isEmpty || githubSecret.trim().isEmpty) {
      throw const AdminException('Paste both the Client ID and the client secret.');
    }
    final problem = await checkGithubApp(
      _web,
      clientId: githubId.trim(),
      secret: githubSecret.trim(),
      callback: githubCallback,
    );
    if (problem != null) throw AdminException(problem);
    step = WizardStep.ai;
  });

  void pickAi(AiPreset? preset) => update(() {
    aiPreset = preset;
    if (preset != null) {
      aiBaseUrl = preset.baseUrl;
      aiModel = preset.model;
    }
  });

  Object? _inputs(ProvisionStep s) => switch (s) {
    ProvisionStep.signIn => (ref, githubId.trim(), githubSecret.trim()),
    ProvisionStep.ai => (ref, aiBaseUrl.trim(), aiModel.trim(), aiKey.trim()),
    _ => ref,
  };

  /// Runs the setup ([withAi] as last chosen when left out, like Retry); a
  /// retry continues after the last finished step, and redoes the ones
  /// whose values changed.
  Future<void> setUp({bool? withAi}) async {
    if (withAi != null) this.withAi = withAi;
    step = WizardStep.setup;
    ready = false;
    current = null;
    done.removeWhere((s) => _doneWith[s] != _inputs(s));
    final ai = usesAi ? (baseUrl: aiBaseUrl, model: aiModel, key: aiKey) : null;
    final inputs = {for (final s in ProvisionStep.values) s: _inputs(s)};
    void finish() {
      if (current case final s?) {
        done.add(s);
        _doneWith[s] = inputs[s];
      }
    }

    await _busy(() async {
      final p = Provisioner(admin: _admin!, ref: ref!, source: source);
      final b = backend = await p.run(
        githubClientId: githubId,
        githubSecret: githubSecret,
        ai: ai,
        done: done,
        onStep: (s) {
          finish();
          current = s;
          notifyListeners();
        },
      );
      finish();
      current = null;
      final problem = await _verify(b);
      if (problem != null) {
        // Most likely sign-in didn't take: Retry sets it again.
        done.remove(ProvisionStep.signIn);
        current = ProvisionStep.signIn;
        throw AdminException(problem);
      }
      ready = true;
    });
  }

  Future<String?> _verify(Backend b) async {
    for (var i = 1; ; i++) {
      final problem = await _check(b);
      if (problem == null || i == 10) return problem;
      await Future<void>.delayed(checkPause);
    }
  }

  /// Connects the app to the finished server ([open] is the session's
  /// connect); a failure shows here and Connect tries again.
  Future<void> connect(Future<void> Function(Backend backend) open) => _busy(() async {
    try {
      await open(backend!);
    } on Object catch (e) {
      throw AdminException("Couldn't connect: $e");
    }
  });

  static String _password() {
    const chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(28, (_) => chars[r.nextInt(chars.length)]).join();
  }

  bool _disposed = false;

  /// Work still running when the wizard goes away (it does once connected)
  /// finishes quietly.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopWaiting?.complete();
    _admin?.close();
    _web.close();
    super.dispose();
  }
}
