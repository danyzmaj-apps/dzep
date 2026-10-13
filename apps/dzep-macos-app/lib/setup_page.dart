import 'package:dzep_core/connect.dart';
import 'package:dzep_core/session.dart';
import 'package:dzep_macos/onboarding/flow.dart';
import 'package:dzep_macos/onboarding/wizard.dart';
import 'package:flutter/material.dart';

/// First run: which Supabase project this Mac syncs through. Džep has no
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
  final _flow = SetupFlow();
  bool _existing = false;

  /// Why connecting to the server the wizard made failed; the connect form
  /// shows it.
  String? _error;

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  /// The wizard's finished server, already checked while it was set up.
  Future<void> _connectNew() async {
    try {
      await widget.session.connect(_flow.backend!);
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Could not connect: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_existing) {
      return SetupWizard(flow: _flow, onConnect: _connectNew, onExisting: () => setState(() => _existing = true));
    }
    return ConnectServerForm(
      session: widget.session,
      error: _error,
      back: (label: '← Set up a new server instead', onPressed: () => setState(() => _existing = false)),
    );
  }
}
