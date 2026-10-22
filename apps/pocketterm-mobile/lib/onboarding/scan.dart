import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/ui.dart';

/// Opens the camera to read the code the computer shows (Settings → Add a
/// phone…): a setup link with a sign-in code in it or, when
/// [signedIn] (a phone adding a computer's key), with that computer's key.
/// Pops with that link, or null when cancelled.
Future<Uri?> scanSetupCode(BuildContext context, {bool signedIn = false}) =>
    Navigator.of(context)
        .push<Uri>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _ScanPage(signedIn: signedIn)));

class _ScanPage extends StatefulWidget {
  const _ScanPage({required this.signedIn});
  final bool signedIn;

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  final _camera = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  /// Set when a QR was read that isn't a PocketTerm code (a Wi-Fi code, a website).
  String? _notOurs;

  @override
  void dispose() {
    unawaited(_camera.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    String? problem;
    for (final code in capture.barcodes) {
      final link = Uri.tryParse(code.rawValue ?? '');
      if (link == null || Backend.fromLink(link) == null) continue;
      final usable = widget.signedIn ? Backend.computerKey(link) != null : Backend.pairingCode(link) != null;
      if (usable) {
        _done = true;
        Navigator.of(context).pop(link);
        return;
      }
      problem = widget.signedIn
          ? 'That code has no key for a computer. Update PocketTerm on your computer, then scan its code in '
                'Settings \u2192 Add a phone\u2026'
          : 'That code has no sign-in in it. Scan the one under Your phone in PocketTerm\u2019s setup checklist '
                'on your computer, or in its Settings \u2192 Add a phone\u2026';
    }
    problem ??= "That's not a PocketTerm code. Scan the one on your computer.";
    if (_notOurs != problem) setState(() => _notOurs = problem);
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
                            _notOurs ??
                                'On your computer: Your phone in PocketTerm\u2019s setup checklist, '
                                    'or Settings \u2192 Add a phone\u2026\nPoint this camera at the code.',
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
              ? 'PocketTerm needs the camera to read the code. Allow it in Settings → PocketTerm → Camera.'
              : "The camera didn't start (${error.errorCode.name}). Close this and try again.",
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, height: 1.5),
        ),
      ),
    ),
  );
}
