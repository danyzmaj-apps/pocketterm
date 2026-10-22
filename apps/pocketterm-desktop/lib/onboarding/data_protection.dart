import 'package:flutter/material.dart';
import 'package:pocketterm_core/ui.dart';

/// How your data is protected, in plain words: the first-run setup shows it
/// (lib/setup_page.dart), Settings → Account opens it again. Kept true to
/// the code: lib/e2e.dart in pocketterm_core, SECURITY.md,
/// apps/pocketterm-relay/SECURITY.md.
class DataProtection extends StatelessWidget {
  const DataProtection({super.key});

  static const sections = <(IconData, String, String)>[
    (
      Icons.lock_outline,
      'Encrypted from end to end',
      'Each computer makes its own key and keeps it in its Keychain (on Windows, a file in %APPDATA% encrypted for your Windows account). A phone gets it '
          'only by scanning that computer’s QR code. Your sessions, prompts, screens, images and notification text '
          'travel sealed with it (AES-256-GCM), so nothing in between can read them.',
    ),
    (
      Icons.dns_outlined,
      'Your PocketTerm server',
      'Keeps your list of devices, your computers’ names, pairing codes for 10 minutes and your phones’ push tokens. '
          'It passes everything else on without being able to read it.',
    ),
    (
      Icons.hub_outlined,
      'Tailscale (On this computer)',
      'Connects your own devices privately. Tailscale sees which of your devices connect and when, not what they '
          'send.',
    ),
    (
      Icons.notifications_none,
      'Notifications, if you turn them on',
      'They go from your server through PocketTerm’s push relay (push.danyzmaj.com, run by Danijel Lovric on his '
          'server in Germany) to Apple or Google, then your phone. The relay, Apple and Google get encrypted text, '
          'your phone’s push token and which computer it’s from. The relay stores nothing.',
    ),
    (
      Icons.info_outline,
      'One exception: Live Activities',
      'On iPhone, a followed session on the Lock Screen (and its ongoing notification on Android) shows its state: '
          'working, needs you or finished, since when, and whether it waits on a question, an approval or a plan. '
          'Apple delivers those to the system directly, so they can’t be encrypted. They never carry any text.',
    ),
    (
      Icons.qr_code_2,
      'The QR code is a key',
      'Whoever scans it can read this computer’s sessions: show it only to your own phone. Settings → Phone → Reset '
          'key makes a new key; every phone then scans the code again.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 14,
    children: [
      for (final (icon, title, text) in sections)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: C.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 3,
                children: [
                  Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  Text(text, style: const TextStyle(fontSize: 12.5, color: C.dim, height: 1.45)),
                ],
              ),
            ),
          ],
        ),
    ],
  );
}

/// [DataProtection] in a dialog (Settings → Account).
Future<void> showDataProtection(BuildContext context) => showDialog<void>(
  context: context,
  builder: (dialog) => AlertDialog(
    key: const ValueKey('data-protection'),
    backgroundColor: C.bar,
    title: const Text('How your data is protected'),
    content: const SizedBox(width: 460, child: SingleChildScrollView(child: DataProtection())),
    actions: [TextButton(onPressed: () => Navigator.of(dialog).pop(), child: const Text('Done'))],
  ),
);
