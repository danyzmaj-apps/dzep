import 'dart:async';

import 'package:dzep_core/connect.dart';
import 'package:dzep_core/logo.dart';
import 'package:dzep_core/session.dart';
import 'package:dzep_core/ui.dart';
import 'package:dzep_mobile/onboarding/scan.dart';
import 'package:flutter/material.dart';

/// First run: which server this iPhone syncs through. The server is set up
/// on the Mac; the iPhone scans the code the Mac shows, which connects and
/// signs in, or takes its setup link pasted.
class SetupPage extends StatefulWidget {
  const SetupPage({required this.session, super.key});
  final Session session;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  bool _paste = false;
  bool _busy = false;
  String? _error;

  /// The Mac's code, read with this iPhone's camera. If the server can't be
  /// reached the app stays here, so the reason shows on this page.
  Future<void> _scan() async {
    final link = await scanSetupCode(context);
    if (link == null || !mounted) return;
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

  @override
  Widget build(BuildContext context) {
    if (_paste) {
      return ConnectServerForm(
        session: widget.session,
        back: (label: '← Scan the code instead', onPressed: () => setState(() => _paste = false)),
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: DzepLogo(size: 56)),
              const SizedBox(height: 14),
              const Text(
                'Welcome to Džep',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              const Text(
                'Džep keeps your ideas, todos and notes on your own free server, so nobody else holds your data.',
                textAlign: TextAlign.center,
                style: TextStyle(color: C.dim, height: 1.5),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: C.field,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: C.line2),
                ),
                child: const Text(
                  '1.  On your Mac, open Džep and set up your server (it guides you).\n'
                  '2.  Then on the Mac: Settings → Set up iPhone. A code appears.\n'
                  '3.  Tap the button below and point this iPhone at it.\n'
                  '4.  That\u2019s it: the iPhone connects and signs in by itself.',
                  style: TextStyle(height: 1.7),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : () => unawaited(_scan()),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: _busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Scan the code from your Mac'),
                ),
              ),
              if (_error case final e?) ...[
                const SizedBox(height: 12),
                Text(
                  e,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Color(0xFFFCA5A5)),
                ),
              ],
              const SizedBox(height: 10),
              TextButton(
                onPressed: _busy ? null : () => setState(() => _paste = true),
                child: const Text('Paste a setup link instead'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
