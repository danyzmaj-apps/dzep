import 'dart:async';

import 'package:dzep_core/backend.dart';
import 'package:dzep_core/connect.dart' show ConfirmLink;
import 'package:dzep_core/logo.dart';
import 'package:dzep_core/session.dart';
import 'package:dzep_core/ui.dart';
import 'package:dzep_mobile/onboarding/scan.dart';
import 'package:flutter/material.dart';

/// What a phone without a session shows: the only way in is a code from the
/// Mac, scanned (its QR) or pasted (the same setup link as text), which
/// connects to the server and signs in. A phone never signs in with GitHub
/// and never sets up a server. After a sign-out, a deleted account or a
/// session the server ended, it says why on top.
class SetupPage extends StatefulWidget {
  const SetupPage({required this.session, super.key});
  final Session session;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _pasted = TextEditingController();
  bool _paste = false;
  bool _busy = false;

  /// What's wrong with the pasted text, before anything is sent.
  String? _invalid;

  Session get session => widget.session;

  @override
  void dispose() {
    _pasted.dispose();
    super.dispose();
  }

  /// The Mac's code, read with this phone's camera.
  Future<void> _scan() async {
    final link = await scanSetupCode(context);
    if (link != null && mounted) await _signIn(link);
  }

  Future<void> _submitPasted() async {
    final link = Uri.tryParse(_pasted.text.trim());
    if (link == null || Backend.pairingCode(link) == null) {
      return setState(
        () => _invalid =
            'Paste the whole code from your Mac: the link that starts with dzep://setup and has a code in it.',
      );
    }
    await _signIn(link);
  }

  /// Connects and signs in; on failure the page stays, with the reason
  /// ([Session.authError]) under the buttons.
  Future<void> _signIn(Uri link) async {
    setState(() {
      _busy = true;
      _invalid = null;
    });
    await session.connectLink(link);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final error = _invalid ?? session.authError;
    return Center(
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
              if (session.signedOutReason case final reason?) ...[
                const SizedBox(height: 10),
                Text(
                  reason,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: C.warn, height: 1.4),
                ),
              ],
              const SizedBox(height: 10),
              const Text(
                'Džep keeps your ideas, todos and notes on your own free server, so nobody else holds your data. '
                'This phone signs in with a code from Džep on your Mac.',
                textAlign: TextAlign.center,
                style: TextStyle(color: C.dim, height: 1.5),
              ),
              const SizedBox(height: 20),
              if (session.linkToConfirm case final link?)
                ConfirmLink(session: session, link: link)
              else if (_paste)
                ..._pasteForm()
              else
                ..._scanSteps(),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Color(0xFFFCA5A5)),
                ),
              ],
              const SizedBox(height: 10),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _paste = !_paste;
                        _invalid = null;
                      }),
                child: Text(_paste ? '← Scan the code instead' : 'Paste a code instead'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _scanSteps() => [
    Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: C.field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.line2),
      ),
      child: const Text(
        '1.  On your Mac, open Džep and set up your server (it guides you).\n'
        '2.  Then on the Mac: Settings → Set up phone. A code appears.\n'
        '3.  Tap the button below and point this phone at it.\n'
        '4.  That\u2019s it: the phone connects and signs in by itself.',
        style: TextStyle(height: 1.7),
      ),
    ),
    const SizedBox(height: 20),
    FilledButton(
      onPressed: _busy ? null : () => unawaited(_scan()),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: _busy ? const _Spinner() : const Text('Scan the code from your Mac'),
      ),
    ),
  ];

  List<Widget> _pasteForm() => [
    const Text(
      'Paste the code you were given: the whole link, as it came (dzep://setup?…).',
      textAlign: TextAlign.center,
      style: TextStyle(height: 1.4),
    ),
    const SizedBox(height: 14),
    TextField(
      controller: _pasted,
      enabled: !_busy,
      autocorrect: false,
      onTapOutside: dismissKeyboard,
      enableSuggestions: false,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.done,
      minLines: 1,
      maxLines: 4,
      decoration: setupField('dzep://setup?url=…&key=…&code=…'),
      onSubmitted: (_) => unawaited(_submitPasted()),
    ),
    const SizedBox(height: 14),
    FilledButton(
      onPressed: _busy ? null : () => unawaited(_submitPasted()),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: _busy ? const _Spinner() : const Text('Sign in'),
      ),
    ),
  ];
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
}
