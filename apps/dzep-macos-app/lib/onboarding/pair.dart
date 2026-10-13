import 'dart:async';

import 'package:dzep_core/session.dart';
import 'package:dzep_core/ui.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// How long a pairing code works (the project's OTP expiry, config.toml).
const pairingLifetime = Duration(minutes: 10);

/// A QR the iPhone's Camera opens in Džep: the server's address plus a
/// one-time sign-in code, so the iPhone is set up and signed in by the scan
/// alone. Anyone who scans it in time gets into the account, so it is made
/// fresh when shown, works once, and hides itself when it runs out.
class PairingQr extends StatefulWidget {
  const PairingQr({required this.session, super.key});
  final Session session;

  @override
  State<PairingQr> createState() => _PairingQrState();
}

class _PairingQrState extends State<PairingQr> {
  late Future<Uri> _link = widget.session.pairingLink();
  Timer? _expiry;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _startExpiry();
  }

  void _startExpiry() {
    _expiry?.cancel();
    _expiry = Timer(pairingLifetime, () {
      if (mounted) setState(() => _expired = true);
    });
  }

  void _renew() => setState(() {
    _link = widget.session.pairingLink();
    _expired = false;
    _startExpiry();
  });

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 210,
        height: 210,
        child: _expired
            ? _placeholder('This code ran out.', action: 'Make a new one')
            : FutureBuilder<Uri>(
                future: _link,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return _placeholder("Couldn't make a code. Check your connection.", action: 'Retry');
                  }
                  final link = snap.data;
                  if (link == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                  return Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                    child: QrImageView(data: link.toString(), padding: EdgeInsets.zero),
                  );
                },
              ),
      ),
      const SizedBox(height: 14),
      const Text(
        'On your iPhone: install Džep, point the Camera at this code and tap "Open in Džep". '
        'It connects and signs in; nothing to type.',
        textAlign: TextAlign.center,
        style: TextStyle(color: C.dim, height: 1.45),
      ),
      const SizedBox(height: 8),
      const Text(
        'The code works once, for 10 minutes. Anyone who scans it gets into your account, so only show it to your own phone.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11.5, color: C.dim2, height: 1.4),
      ),
    ],
  );

  Widget _placeholder(String text, {required String action}) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: C.dim),
      ),
      const SizedBox(height: 8),
      TextButton(onPressed: _renew, child: Text(action)),
    ],
  );
}

/// Mac Settings → "Set up iPhone".
Future<void> showPairingQr(BuildContext context, Session session) => showDialog<void>(
  context: context,
  builder: (dialog) => AlertDialog(
    backgroundColor: C.bar,
    title: const Text('Set up your iPhone'),
    content: SizedBox(width: 320, child: PairingQr(session: session)),
    actions: [TextButton(onPressed: () => Navigator.of(dialog).pop(), child: const Text('Done'))],
  ),
);
