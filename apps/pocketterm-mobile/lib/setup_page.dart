import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketterm_core/connect.dart' show ConfirmLink;
import 'package:pocketterm_core/logo.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/links.dart';
import 'package:pocketterm_mobile/onboarding/scan.dart';

/// What a phone without a session shows: the only way in is the code
/// PocketTerm on the computer shows, scanned with this phone's camera, which
/// connects to the server, signs in and brings that computer's key. A phone
/// never signs in with GitHub and never sets up a server. "Try the demo"
/// shows the app on a made-up computer instead. After a sign-out, a deleted
/// account or a session the server ended, it says why on top.
class SetupPage extends StatefulWidget {
  const SetupPage({required this.session, this.onDemo, @visibleForTesting this.scan = scanSetupCode, super.key});
  final Session session;

  /// "Try the demo"; no button without it.
  final VoidCallback? onDemo;

  /// Reads the computer's code: the camera (tests hand in a link).
  final Future<Uri?> Function(BuildContext context) scan;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  bool _busy = false;

  Session get session => widget.session;

  /// Connects and signs in with the code the camera read; on failure the
  /// page stays, with the reason ([Session.authError]) under the button.
  Future<void> _scan() async {
    final link = await widget.scan(context);
    if (link == null || !mounted) return;
    setState(() => _busy = true);
    await session.connectLink(link, scanned: true);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final error = session.authError;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: PocketTermLogo(size: 56)),
              const SizedBox(height: 14),
              const Text(
                'Welcome to PocketTerm',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              if (session.signedOutReason case final reason?) ...[
                const SizedBox(height: 10),
                Text(
                  reason,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: C.warn, height: 1.4),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                'Your computer\u2019s coding sessions on your phone, end-to-end encrypted. This phone connects by '
                'scanning the code PocketTerm on your computer shows.',
                textAlign: TextAlign.center,
                style: TextStyle(color: C.dim, height: 1.5),
              ),
              const SizedBox(height: 20),
              if (session.linkToConfirm case final link?)
                ConfirmLink(session: session, link: link)
              else
                ..._scanSteps(),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: C.error),
                ),
              ],
              if (widget.onDemo case final onDemo?) ...[
                const SizedBox(height: 18),
                OutlinedButton(
                  key: const ValueKey('try-demo'),
                  onPressed: _busy ? null : onDemo,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: C.line2, width: C.border),
                  ),
                  child: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Try the demo')),
                ),
                const SizedBox(height: 6),
                Text(
                  'No computer yet? See PocketTerm with made-up sessions. Nothing connects.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: C.dim, height: 1.4),
                ),
              ],
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
        borderRadius: C.round(12),
        border: Border.all(color: C.line2, width: C.border),
      ),
      child: const Text(
        '1.  Install PocketTerm on your computer and open it. Its setup connects it to your server.\n'
        '2.  On the computer, open Settings \u2192 Add\u00A0a\u00A0phone\u2026 to show a code.\n'
        '3.  Tap the button below and point this phone at it.\n'
        '4.  That\u2019s it: the phone connects and signs in by itself.',
        style: TextStyle(height: 1.7),
      ),
    ),
    // Step 1 needs PocketTerm on the computer: where to get it.
    Align(
      child: TextButton.icon(
        key: const ValueKey('get-desktop'),
        onPressed: () => openExternal(desktopDownloadsUrl),
        icon: const Icon(Icons.open_in_new, size: 15),
        label: const Text('Get PocketTerm for Mac or Windows'),
      ),
    ),
    const SizedBox(height: 8),
    FilledButton(
      key: const ValueKey('scan-code'),
      onPressed: _busy ? null : () => unawaited(_scan()),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: _busy ? const _Spinner() : const Text('Scan the code from your computer'),
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
