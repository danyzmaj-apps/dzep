import 'dart:async';
import 'dart:math';

import 'package:dzep/backend.dart';
import 'package:dzep/onboarding/provision.dart';
import 'package:dzep/onboarding/supabase_admin.dart';
import 'package:flutter/foundation.dart';

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

/// The setup wizard: Supabase access → a project → GitHub sign-in → AI →
/// [Provisioner] does the rest. The access token and the secrets only live
/// in this object; nothing here is saved.
class SetupFlow extends ChangeNotifier {
  SetupFlow({SupabaseAdmin Function(String token)? admin, this.source = const AssetBackendSource()})
    : _newAdmin = admin ?? SupabaseAdmin.new;

  final SupabaseAdmin Function(String token) _newAdmin;
  final BackendSource source;

  WizardStep step = WizardStep.welcome;
  bool busy = false;
  String? error;

  // ---- Supabase access
  SupabaseAdmin? _admin;
  List<Org> orgs = const [];
  List<Project> projects = const [];

  /// Projects that can hold a Džep server (running ones).
  List<Project> get usableProjects => projects.where((p) => p.status == 'ACTIVE_HEALTHY').toList();

  // ---- project choice
  bool createNew = true;
  String newName = 'dzep';
  String? org;
  String region = guessRegion(DateTime.now().timeZoneOffset);
  String? existingRef;
  String? ref;

  /// While a new project starts.
  String? waiting;

  // ---- GitHub
  String githubId = '';
  String githubSecret = '';

  // ---- AI
  AiPreset? aiPreset = aiPresets.first;
  String aiBaseUrl = aiPresets.first.baseUrl;
  String aiModel = aiPresets.first.model;
  String aiKey = '';

  // ---- setup
  final Set<ProvisionStep> done = {};
  ProvisionStep? current;
  Backend? backend;

  String get githubCallback => 'https://$ref.supabase.co/auth/v1/callback';

  void go(WizardStep s) {
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
    org ??= o.first.slug;
    // An existing project called dzep is most likely a previous attempt.
    final named = usableProjects.where((x) => x.name == 'dzep').firstOrNull;
    if (named != null) {
      createNew = false;
      existingRef = named.ref;
    }
    step = WizardStep.project;
  });

  /// Creates the project (and waits for it) or takes the chosen one.
  Future<void> submitProject() => _busy(() async {
    final admin = _admin!;
    if (createNew) {
      final name = newName.trim().isEmpty ? 'dzep' : newName.trim();
      final p = await admin.createProject(org: org!, name: name, region: region, dbPassword: _password());
      ref = p.ref;
      waiting = 'Starting your project. This takes a minute or two…';
      notifyListeners();
      await admin.waitUntilReady(p.ref);
      waiting = null;
    } else {
      final r = existingRef;
      if (r == null) throw const AdminException('Pick a project.');
      ref = r;
    }
    step = WizardStep.github;
  }).whenComplete(() => waiting = null);

  void submitGithub() {
    if (githubId.trim().isEmpty || githubSecret.trim().isEmpty) {
      error = 'Paste both the Client ID and the client secret.';
    } else {
      step = WizardStep.ai;
      error = null;
    }
    notifyListeners();
  }

  void pickAi(AiPreset? preset) => update(() {
    aiPreset = preset;
    if (preset != null) {
      aiBaseUrl = preset.baseUrl;
      aiModel = preset.model;
    }
  });

  /// Runs the setup; a retry continues after the last finished step.
  Future<void> setUp({required bool withAi}) async {
    step = WizardStep.setup;
    final ai = withAi && aiKey.trim().isNotEmpty ? (baseUrl: aiBaseUrl, model: aiModel, key: aiKey) : null;
    await _busy(() async {
      final p = Provisioner(admin: _admin!, ref: ref!, source: source);
      backend = await p.run(
        githubClientId: githubId,
        githubSecret: githubSecret,
        ai: ai,
        done: done,
        onStep: (s) {
          if (current != null) done.add(current!);
          current = s;
          notifyListeners();
        },
      );
      if (current != null) done.add(current!);
      current = null;
      final problem = await backend!.check();
      if (problem != null) throw AdminException(problem);
    });
  }

  static String _password() {
    const chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(28, (_) => chars[r.nextInt(chars.length)]).join();
  }

  @override
  void dispose() {
    _admin?.close();
    super.dispose();
  }
}
