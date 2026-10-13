import 'dart:async';

import 'package:dzep_core/chat.dart';
import 'package:dzep_core/ui.dart';
import 'package:dzep_macos/controller.dart';
import 'package:dzep_macos/onboarding/flow.dart' show AiPreset, aiPresets;
import 'package:dzep_macos/onboarding/provision.dart';
import 'package:dzep_macos/onboarding/supabase_admin.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const _tokensUrl = 'https://supabase.com/dashboard/account/tokens';

/// The Supabase project behind [url] (`https://<ref>.supabase.co`); null for
/// a server elsewhere (a local or self-run Supabase), which the Management
/// API can't reach.
String? projectRef(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  const suffix = '.supabase.co';
  if (!host.endsWith(suffix)) return null;
  final ref = host.substring(0, host.length - suffix.length);
  return ref.isEmpty || ref.contains('.') ? null : ref;
}

/// Mac Settings → AI, and Ask's "Connect an AI…": sets the AI that answers
/// Ask on the user's server, the way the setup wizard's AI step does. How it
/// went shows as a toast in [context]'s window.
Future<void> showConnectAi(BuildContext context, AppController app) {
  final toaster = context.findAncestorStateOfType<ToasterState>();
  return showDialog<void>(
    context: context,
    builder: (_) => ConnectAiSheet(app: app, onDone: (message) => toaster?.show(message)),
  );
}

/// The provider (the wizard's presets, or any OpenAI-compatible API), its
/// key, and a Supabase access token that saves them as the `ask` function's
/// secrets. The token is used for that alone and never kept.
class ConnectAiSheet extends StatefulWidget {
  const ConnectAiSheet({required this.app, required this.onDone, this.admin = SupabaseAdmin.new, super.key});
  final AppController app;

  /// After saving, with what to tell the user; the sheet then closes.
  final ValueChanged<String> onDone;
  final SupabaseAdmin Function(String token) admin;

  @override
  State<ConnectAiSheet> createState() => _ConnectAiSheetState();
}

class _ConnectAiSheetState extends State<ConnectAiSheet> {
  late final AiStatus? _current = widget.app.chats?.ai;

  /// The connected provider, if it's one of the presets.
  late AiPreset? _preset = _current?.baseUrl == null
      ? aiPresets.first
      : aiPresets.where((p) => p.baseUrl == _current?.baseUrl && p.model == _current?.model).firstOrNull;
  late final _url = TextEditingController(text: _current?.baseUrl ?? '');
  late final _model = TextEditingController(text: _current?.model ?? '');
  final _key = TextEditingController();
  final _token = TextEditingController();
  late final String? _ref = projectRef(widget.app.backend?.url ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_url, _model, _key, _token]) {
      c.dispose();
    }
    super.dispose();
  }

  /// What's wrong with the form, if anything.
  String? _problem(AiSettings ai, String token) {
    final url = Uri.tryParse(ai.baseUrl);
    if (url == null || !(url.isScheme('https') || url.isScheme('http')) || url.host.isEmpty) {
      return 'The API base URL starts with https:// (or http:// on your own network).';
    }
    if (ai.model.isEmpty) return 'Type the model.';
    if (ai.key.isEmpty) return 'Paste the API key.';
    if (!token.startsWith('sbp_')) return 'Paste a Supabase access token: it starts with sbp_.';
    return null;
  }

  Future<void> _connect() async {
    if (_busy) return;
    final preset = _preset;
    final ai = (
      baseUrl: preset?.baseUrl ?? _url.text.trim(),
      model: preset?.model ?? _model.text.trim(),
      key: _key.text.trim(),
    );
    final token = _token.text.trim();
    final problem = _problem(ai, token);
    setState(() {
      _error = problem;
      _busy = problem == null;
    });
    if (problem != null) return;
    final admin = widget.admin(token);
    try {
      await Provisioner(admin: admin, ref: _ref!).setAi(ai);
    } on AdminException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
      return;
    } finally {
      admin.close();
    }
    // The function sees new secrets within moments; ask until it does.
    final chats = widget.app.chats;
    var connected = chats == null;
    for (var i = 0; i < 5 && !connected; i++) {
      if (i > 0) await Future<void>.delayed(const Duration(seconds: 2));
      // An older server can't say: take it as done.
      connected = (await chats!.checkAi())?.connected ?? true;
    }
    if (!mounted) return;
    widget.onDone(connected ? 'AI connected ✓' : 'Saved. Ask picks it up within a few minutes.');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final preset = _preset;
    final ref = _ref;
    return AlertDialog(
      backgroundColor: C.bar,
      title: Text(_current?.connected ?? false ? 'Change the AI' : 'Connect an AI'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: ref == null
              ? const Text(
                  'Your server isn’t on supabase.com, so Džep can’t set its AI from here. Set the secrets '
                  'AI_BASE_URL, AI_MODEL and AI_API_KEY with `supabase secrets set` (see docs/SELF_HOSTING.md).',
                  style: TextStyle(color: C.dim, height: 1.45),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Ask answers short questions using an AI service you choose; you pay it directly, usually '
                      'cents a month. The key is kept on your server, never in the apps.',
                      style: TextStyle(color: C.dim, height: 1.45),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final p in aiPresets)
                          ChoiceChip(
                            label: Text(p.name),
                            selected: preset == p,
                            onSelected: _busy ? null : (_) => setState(() => _preset = p),
                          ),
                        ChoiceChip(
                          label: const Text('Other'),
                          selected: preset == null,
                          onSelected: _busy ? null : (_) => setState(() => _preset = null),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (preset != null) _link('Get a ${preset.name} API key', preset.keysUrl),
                    if (preset == null) ...[
                      _field(_url, 'API base URL (OpenAI-compatible)'),
                      const SizedBox(height: 8),
                      _field(_model, 'Model'),
                      const SizedBox(height: 8),
                    ],
                    _field(_key, 'API key', secret: true),
                    const SizedBox(height: 18),
                    const Text(
                      'To save it on your server, Džep needs a Supabase access token once. Create one '
                      '(name it "Džep AI"), paste it here, and delete it afterwards if you like.',
                      style: TextStyle(color: C.dim, height: 1.45),
                    ),
                    _link('Open Supabase access tokens', _tokensUrl),
                    _field(_token, 'Access token (sbp_…)', secret: true),
                    const SizedBox(height: 6),
                    const Text(
                      'Used once to save the key; Džep never keeps it.',
                      style: TextStyle(fontSize: 11.5, color: C.dim2),
                    ),
                    if (_error case final e?) ...[
                      const SizedBox(height: 12),
                      Text(e, style: const TextStyle(color: Color(0xFFFCA5A5))),
                    ],
                  ],
                ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(ref == null ? 'Done' : 'Cancel')),
        if (ref != null)
          FilledButton(
            onPressed: _busy ? null : () => unawaited(_connect()),
            child: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Connect'),
          ),
      ],
    );
  }

  Widget _field(TextEditingController controller, String hint, {bool secret = false}) => TextField(
    controller: controller,
    enabled: !_busy,
    autocorrect: false,
    obscureText: secret,
    decoration: setupField(hint),
    onSubmitted: (_) => unawaited(_connect()),
  );

  Widget _link(String label, String url) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      onPressed: () => unawaited(launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)),
      icon: const Icon(Icons.open_in_new, size: 15),
      label: Text(label),
      style: TextButton.styleFrom(padding: EdgeInsets.zero),
    ),
  );
}
