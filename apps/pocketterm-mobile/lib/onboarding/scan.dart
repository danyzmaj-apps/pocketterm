import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/native.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart' show isIos;
import 'package:pocketterm_mobile/e2e_hooks.dart';

/// Opens the camera to read the code the computer shows (Settings → Add a
/// phone…): a setup link with a sign-in code in it or, when
/// [signedIn] (a phone adding a computer's key), with that computer's key.
/// Pops with that link, or null when cancelled. [pasteCode]: a field takes
/// the link too, as if the camera had read it (E2E debug builds only).
Future<Uri?> scanSetupCode(
  BuildContext context, {
  bool signedIn = false,
  @visibleForTesting bool pasteCode = e2eBuild,
}) => Navigator.of(context).push<Uri>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _ScanPage(signedIn: signedIn, pasteCode: pasteCode),
  ),
);

class _ScanPage extends StatefulWidget {
  const _ScanPage({required this.signedIn, required this.pasteCode});
  final bool signedIn;
  final bool pasteCode;

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

  void _onDetect(BarcodeCapture capture) => _read([for (final code in capture.barcodes) code.rawValue]);

  /// What the camera (or, in debug builds, [_PasteCode]) read: the first
  /// usable PocketTerm link pops; otherwise says why none was.
  void _read(Iterable<String?> codes) {
    if (_done) return;
    String? problem;
    for (final raw in codes) {
      final link = Uri.tryParse(raw?.trim() ?? '');
      if (link == null) continue;
      if (Backend.fromLink(link) == null) continue;
      final usable = widget.signedIn ? Backend.computerKey(link) != null : Backend.pairingCode(link) != null;
      if (usable) {
        _done = true;
        Navigator.of(context).pop(link);
        return;
      }
      problem = widget.signedIn
          ? 'That code has no key for a computer. Update PocketTerm on your computer, then scan its code in '
                'Settings \u2192 Phone \u2192 Add a phone\u2026'
          : 'That code has no sign-in in it. Scan the one under Your phone in PocketTerm\u2019s setup checklist '
                'on your computer, or in its Settings \u2192 Phone \u2192 Add a phone\u2026';
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
                                decoration: BoxDecoration(color: Colors.white, borderRadius: C.round(24)),
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
                            borderRadius: C.round(24),
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
                                    'or Settings \u2192 Phone \u2192 Add a phone\u2026\nPoint this camera at the code.',
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
          // The Simulator and emulators have no camera: E2E debug builds take
          // the link a code holds, as if the camera had read it (maestro/e2e).
          // kDebugMode is a constant false in release and profile builds, so
          // the field isn't compiled into them at all.
          if (kDebugMode && widget.pasteCode)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                // Why a code didn't work shows under the square, unless the camera's problem took the screen.
                child: ValueListenableBuilder(
                  valueListenable: _camera,
                  builder: (context, state, _) =>
                      _PasteCode(problem: state.error != null ? _notOurs : null, onCode: (code) => _read([code])),
                ),
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

/// Debug builds only: a code's link, pasted instead of scanned.
class _PasteCode extends StatefulWidget {
  const _PasteCode({required this.onCode, this.problem});
  final ValueChanged<String> onCode;
  final String? problem;

  @override
  State<_PasteCode> createState() => _PasteCodeState();
}

class _PasteCodeState extends State<_PasteCode> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.problem case final problem?)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(problem, style: TextStyle(color: C.warn)),
          ),
        Row(
          children: [
            Expanded(
              // Named for UI tests: below Android 9 Flutter reads no text field's hint.
              child: Semantics(
                identifier: 'paste-code',
                child: TextField(
                  key: const ValueKey('paste-code'),
                  controller: _text,
                  // A link: Android 8's keyboard "corrected" url= to URL= and d= to do=.
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(hintText: 'Paste a code (debug)', isDense: true),
                  onSubmitted: widget.onCode,
                ),
              ),
            ),
            TextButton(
              key: const ValueKey('paste-code-use'),
              onPressed: () => widget.onCode(_text.text),
              child: const Text('Use'),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Why the camera shows nothing: not allowed (with the way to Settings), no
/// camera at all (an iPad or phone without one, the Simulator), or it
/// failed to start.
class _CameraProblem extends StatelessWidget {
  const _CameraProblem(this.error);
  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                switch (error.errorCode) {
                  MobileScannerErrorCode.permissionDenied =>
                    isIos
                        ? 'PocketTerm needs the camera to read the code. Allow it in Settings \u2192 PocketTerm '
                              '\u2192 Camera.'
                        : 'PocketTerm needs the camera to read the code. Allow it in Settings \u2192 Apps '
                              '\u2192 PocketTerm \u2192 Permissions.',
                  MobileScannerErrorCode.unsupported =>
                    "This device has no camera PocketTerm can use, so it can't read the code. Connect with a "
                        'phone that has one, or close this and try the demo.',
                  final code => "The camera didn't start (${code.name}). Close this and try again.",
                },
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, height: 1.5),
              ),
              if (denied) ...[
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('camera-settings'),
                  onPressed: () => unawaited(Native.openSettings()),
                  child: const Text('Open Settings'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
