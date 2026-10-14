import 'dart:async';

import 'package:dzep_core/backend.dart';
import 'package:dzep_core/logo.dart';
import 'package:dzep_core/session.dart';
import 'package:dzep_core/ui.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const selfHostingGuide = 'https://github.com/danyzmaj-apps/dzep/blob/main/docs/SELF_HOSTING.md';

/// Connects this device to a server that already exists: its setup link
/// (pairing code and all), or its URL and publishable key.
class ConnectServerForm extends StatefulWidget {
  const ConnectServerForm({required this.session, this.back, super.key});
  final Session session;

  /// The way back to where the form was opened from, if any.
  final ({String label, VoidCallback onPressed})? back;

  @override
  State<ConnectServerForm> createState() => _ConnectServerFormState();
}

class _ConnectServerFormState extends State<ConnectServerForm> {
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
    // A whole setup link pasted into the URL field works too, pairing code
    // and all.
    final link = Uri.tryParse(_url.text.trim());
    if (link != null && Backend.fromLink(link) != null) return await _connectLink(link);
    final parsed = Backend.parse(_url.text, _key.text);
    final backend = parsed.backend;
    if (backend == null) return setState(() => _error = parsed.error);
    await _use(backend);
  }

  /// Connects (and with a pairing code, signs in). If the server can't be
  /// reached the form stays, so the reason shows on it.
  Future<void> _connectLink(Uri link) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.session.connectLink(link);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (widget.session.backend == null) _error = widget.session.authError;
    });
  }

  Future<void> _use(Backend backend) async {
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

  @override
  Widget build(BuildContext context) {
    final back = widget.back;
    return Center(
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
              if (back != null) TextButton(onPressed: back.onPressed, child: Text(back.label)),
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
}

/// A setup link from outside the app to another server
/// ([Session.linkToConfirm]): nothing happens until the person says yes.
/// Anyone can send such a link, and whatever this device saves afterwards
/// would go to that server.
class ConfirmLink extends StatelessWidget {
  const ConfirmLink({required this.session, required this.link, super.key});
  final Session session;
  final Uri link;

  @override
  Widget build(BuildContext context) {
    final host = Backend.fromLink(link)?.host ?? '?';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.warn),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Connect to $host?', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            'A link asks to connect Džep to this server. Only connect if you opened it yourself, from your own '
            'Mac or server: everything you save afterwards goes there.',
            style: TextStyle(color: C.dim, height: 1.4),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => unawaited(session.answerLink(connect: false)), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(onPressed: () => unawaited(session.answerLink(connect: true)), child: const Text('Connect')),
            ],
          ),
        ],
      ),
    );
  }
}
