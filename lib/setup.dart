import 'dart:async';

import 'package:dzep/backend.dart';
import 'package:dzep/session.dart';
import 'package:dzep/ui.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const selfHostingGuide = 'https://github.com/danyzmaj-apps/dzep/blob/main/docs/SELF_HOSTING.md';

/// First run: which Supabase project this device syncs through. Džep has no
/// server of its own; every user runs theirs (docs/SELF_HOSTING.md).
class SetupPage extends StatefulWidget {
  const SetupPage({required this.session, super.key});
  final Session session;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    // A whole setup link pasted into the URL field works too.
    final link = Uri.tryParse(_url.text.trim());
    final fromLink = link == null ? null : Backend.fromLink(link);
    final parsed = fromLink != null ? (backend: fromLink, error: null) : Backend.parse(_url.text, _key.text);
    final backend = parsed.backend;
    if (backend == null) return setState(() => _error = parsed.error);
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await backend.check();
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

  InputDecoration _field(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: C.dim2),
    filled: true,
    fillColor: C.field,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: C.line2),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: C.line2),
    ),
  );

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('💡', textAlign: TextAlign.center, style: TextStyle(fontSize: 40)),
            const SizedBox(height: 14),
            const Text(
              'Connect your Supabase project',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Džep keeps your ideas in your own Supabase project, so nobody else holds your data. '
              'Paste the setup link the setup script printed, or the project URL and publishable key.',
              textAlign: TextAlign.center,
              style: TextStyle(color: C.dim, height: 1.4),
            ),
            const SizedBox(height: 22),
            TextField(
              controller: _url,
              enabled: !_busy,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: _field('https://abcdefgh.supabase.co  or  dzep://setup?…'),
              onSubmitted: (_) => unawaited(_connect()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _key,
              enabled: !_busy,
              autocorrect: false,
              decoration: _field('Publishable key (sb_publishable_…)'),
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
              onPressed: () => unawaited(launchUrl(Uri.parse(selfHostingGuide))),
              child: const Text("Don't have one yet? Set it up in about 10 minutes →", textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    ),
  );
}
