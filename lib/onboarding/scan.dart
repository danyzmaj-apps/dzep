import 'dart:async';

import 'package:dzep/backend.dart';
import 'package:dzep/ui.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Opens the camera to read the setup code the Mac shows (Settings → Set up
/// iPhone). Pops with the setup link, or null when cancelled.
Future<Uri?> scanSetupCode(BuildContext context) =>
    Navigator.of(context).push<Uri>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _ScanPage()));

class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  final _camera = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  /// Set when a QR was read that isn't a Džep code (a Wi-Fi code, a website).
  String? _notOurs;

  @override
  void dispose() {
    unawaited(_camera.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final code in capture.barcodes) {
      final link = Uri.tryParse(code.rawValue ?? '');
      if (link != null && Backend.fromLink(link) != null) {
        _done = true;
        Navigator.of(context).pop(link);
        return;
      }
    }
    if (_notOurs == null) setState(() => _notOurs = "That's not a Džep code. Scan the one on your Mac.");
  }

  @override
  Widget build(BuildContext context) {
    const box = 260.0;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _camera,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _CameraProblem(error),
          ),
          // The framing square and hint, gone when the camera can't run
          // (the error message takes the screen instead).
          ValueListenableBuilder(
            valueListenable: _camera,
            builder: (context, state, _) => state.error != null
                ? const SizedBox.shrink()
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      // Dims everything outside the square the code goes in.
                      ColorFiltered(
                        colorFilter: const ColorFilter.mode(Color(0x99000000), BlendMode.srcOut),
                        child: Stack(
                          children: [
                            Container(
                              decoration: const BoxDecoration(
                                color: Colors.black,
                                backgroundBlendMode: BlendMode.dstOut,
                              ),
                            ),
                            Center(
                              child: Container(
                                width: box,
                                height: box,
                                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Center(
                        child: Container(
                          width: box,
                          height: box,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white, width: 3),
                          ),
                        ),
                      ),
                      // Under the square.
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(32, box + 80, 32, 0),
                          child: Text(
                            _notOurs ?? 'On your Mac: Settings → Set up iPhone.\nPoint this camera at the code.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _notOurs == null ? Colors.white : C.warn,
                              fontSize: 15,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                tooltip: 'Cancel',
                color: Colors.white,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraProblem extends StatelessWidget {
  const _CameraProblem(this.error);
  final MobileScannerException error;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          error.errorCode == MobileScannerErrorCode.permissionDenied
              ? 'Džep needs the camera to read the code. Allow it in Settings → Džep → Camera, '
                    'or paste the setup link instead.'
              : "The camera didn't start (${error.errorCode.name}). Paste the setup link instead.",
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, height: 1.5),
        ),
      ),
    ),
  );
}
