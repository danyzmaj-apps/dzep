import 'dart:async';

import 'package:dzep/backend.dart';
import 'package:dzep/logo.dart';
import 'package:dzep/onboarding/flow.dart';
import 'package:dzep/onboarding/scan.dart';
import 'package:dzep/onboarding/wizard.dart';
import 'package:dzep/session.dart';
import 'package:dzep/ui.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const selfHostingGuide = 'https://github.com/danyzmaj-apps/dzep/blob/main/docs/SELF_HOSTING.md';

/// First run: which Supabase project this device syncs through. Džep has no
/// server of its own; every user runs theirs. The wizard sets one up from
/// scratch (lib/onboarding/); a server that already exists connects with
/// its setup link, or URL and key.
class SetupPage extends StatefulWidget {
  const SetupPage({required this.session, super.key});
  final Session session;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  final _flow = SetupFlow();
  bool _existing = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _flow.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    // A whole setup link pasted into the URL field works too, pairing code
    // and all.
    final link = Uri.tryParse(_url.text.trim());
    if (link != null && Backend.fromLink(link) != null) return await _connectLink(link);
    final parsed = Backend.parse(_url.text, _key.text);
    final backend = parsed.backend;
    if (backend == null) return setState(() => _error = parsed.error);
    await _use(backend, check: true);
  }

  /// The Mac's code, read with this iPhone's camera.
  Future<void> _scan() async {
    final link = await scanSetupCode(context);
    if (link != null && mounted) await _connectLink(link);
  }

  /// Connects (and with a pairing code, signs in). If the server can't be
  /// reached the app stays here, so the reason shows on this page.
  Future<void> _connectLink(Uri link) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.session.connectLink(link);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (widget.session.backend == null && widget.session.authError != null) {
        _error = widget.session.authError;
        _existing = true;
      }
    });
  }

  Future<void> _use(Backend backend, {required bool check}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = check ? await backend.check() : null;
    if (problem == null) {
      try {
        await widget.session.connect(backend);
      } on Object catch (e) {
        _error = 'Could not connect: $e';
      }
    } else {
      _error = problem;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_existing) {
      return SetupWizard(
        flow: _flow,
        onConnect: () => _use(_flow.backend!, check: false),
        onExisting: () => setState(() => _existing = true),
        onScan: () => unawaited(_scan()),
      );
    }
    return _existingForm();
  }

  Widget _existingForm() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: DzepLogo(size: 56)),
            const SizedBox(height: 14),
            const Text(
              'Connect your server',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Paste its setup link (on another device: Settings → Copy setup link), or the project URL '
              'and publishable key.',
              textAlign: TextAlign.center,
              style: TextStyle(color: C.dim, height: 1.4),
            ),
            const SizedBox(height: 22),
            TextField(
              controller: _url,
              enabled: !_busy,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: setupField('https://abcdefgh.supabase.co  or  dzep://setup?…'),
              onSubmitted: (_) => unawaited(_connect()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _key,
              enabled: !_busy,
              autocorrect: false,
              decoration: setupField('Publishable key (sb_publishable_…)'),
              onSubmitted: (_) => unawaited(_connect()),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : () => unawaited(_connect()),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Connect'),
              ),
            ),
            if ((_error ?? widget.session.authError) != null) ...[
              const SizedBox(height: 12),
              Text(
                _error ?? widget.session.authError!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0xFFFCA5A5)),
              ),
            ],
            const SizedBox(height: 18),
            TextButton(
              onPressed: () => setState(() => _existing = false),
              child: const Text('← Set up a new server instead'),
            ),
            TextButton(
              onPressed: () => unawaited(launchUrl(Uri.parse(selfHostingGuide))),
              style: TextButton.styleFrom(foregroundColor: C.dim2),
              child: const Text('Self-hosting guide'),
            ),
          ],
        ),
      ),
    ),
  );
}
