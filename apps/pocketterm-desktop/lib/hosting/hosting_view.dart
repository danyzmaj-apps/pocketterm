import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/hosting/built_in_server.dart';
import 'package:pocketterm_desktop/hosting/tailscale.dart';
import 'package:url_launcher/url_launcher.dart';

void openLink(Uri url) => unawaited(launchUrl(url, mode: LaunchMode.externalApplication));

/// The phone needs Tailscale too, on the same account; this setup and the
/// phone's QR (lib/onboarding/get_ready.dart) both say so.
const phoneTailscaleNote =
    'Your phone needs the Tailscale app too, signed in to the same Tailscale account. Get it from the App Store or '
    'Google Play. If Tailscale says Awaiting Approval, approve this phone in the Tailscale admin console under '
    'Machines.';

/// A small outlined button, as the setup screens use them.
Widget smallButton(String label, VoidCallback? onPressed, {Key? key}) => OutlinedButton(
  key: key,
  onPressed: onPressed,
  style: OutlinedButton.styleFrom(
    foregroundColor: C.text,
    side: const BorderSide(color: C.line2),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    visualDensity: VisualDensity.compact,
  ),
  child: Text(label, style: const TextStyle(fontSize: 12.5)),
);

/// Where the built-in server stands, in a line, with what to do about it:
/// install or open Tailscale, turn HTTPS on, look again.
class HostingStatusView extends StatelessWidget {
  const HostingStatusView({required this.server, super.key});
  final BuiltInServer server;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: server,
    builder: (context, _) {
      final ts = server.tailscale;
      final (text, ok, actions) = switch (server.state) {
        HostState.checking => ('Looking for Tailscale…', null, const <Widget>[]),
        HostState.noTailscale => (
          'Tailscale isn’t installed. Your phone reaches this computer through it.',
          false,
          [smallButton('Install Tailscale', () => openLink(Tailscale.download))],
        ),
        HostState.tailscaleOff => (
          'Tailscale isn’t running. Open it and switch it on.',
          false,
          [smallButton('Open Tailscale', () => unawaited(ts.open())), _again()],
        ),
        HostState.loggedOut => (
          'Tailscale is signed out. Open it and sign in.',
          false,
          [smallButton('Open Tailscale', () => unawaited(ts.open())), _again()],
        ),
        HostState.httpsOff => (
          'HTTPS is off for your tailnet. Turn it on, so your phone gets a secure address for this computer.',
          false,
          [
            smallButton(
              'Turn on HTTPS…',
              () => openLink(server.enableHttps ?? Tailscale.adminDns),
              key: const ValueKey('hosting-enable-https'),
            ),
            _again(),
          ],
        ),
        HostState.failed => ('Tailscale didn’t publish the server: ${server.error}', false, [_again()]),
        HostState.taken => (server.error ?? '', false, [_again()]),
        HostState.ready => ('Tailscale serves it to your own devices at ${server.publicUrl}', true, const <Widget>[]),
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: SizedBox.square(
                  dimension: 16,
                  child: switch (ok) {
                    null => const Padding(padding: EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2)),
                    true => const Icon(Icons.check, size: 16, color: C.ok),
                    false => const Icon(Icons.warning_amber_rounded, size: 16, color: C.warn),
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text, style: const TextStyle(fontSize: 12.5, color: C.dim, height: 1.45)),
              ),
            ],
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: Wrap(spacing: 8, runSpacing: 8, children: actions),
            ),
          if (server.state == HostState.ready)
            if (server.renamedFrom case final old?)
              Padding(
                key: const ValueKey('hosting-renamed'),
                padding: const EdgeInsets.only(left: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    Text(
                      'This computer’s Tailscale address changed from ${old.host}. Phones and computers set up '
                      'with the old one can’t reach it: scan this computer’s code again on each phone (Add a '
                      'phone…), and paste a new link on each other computer (Add a computer…).',
                      style: const TextStyle(fontSize: 12.5, color: C.warn, height: 1.45),
                    ),
                    smallButton('Got it', server.renameSeen, key: const ValueKey('hosting-renamed-seen')),
                  ],
                ),
              ),
        ],
      );
    },
  );

  Widget _again() => smallButton('Check again', () => unawaited(server.refresh()));
}

/// Settings → Account → "Add a computer…": the setup link another computer
/// pastes (Your own server) to join this computer's server through
/// Tailscale.
Future<void> showAddComputer(BuildContext context, Uri link) => showDialog<void>(
  context: context,
  builder: (dialog) => AlertDialog(
    backgroundColor: C.bar,
    title: const Text('Add a computer'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          const Text(
            'On the other computer, sign in to Tailscale with the same account, install PocketTerm, choose '
            'Your own server and paste this link.',
            style: TextStyle(color: C.dim, height: 1.45),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: C.field,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: C.line2),
            ),
            child: SelectableText(
              '$link',
              key: const ValueKey('add-computer-link'),
              style: const TextStyle(fontSize: 12, fontFamily: 'Menlo', height: 1.4),
            ),
          ),
          const Text(
            'Anyone who has this link can sign a computer in to your server. Send it only to yourself.',
            style: TextStyle(fontSize: 11.5, color: C.dim2, height: 1.4),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          unawaited(Clipboard.setData(ClipboardData(text: '$link')));
          Toaster.of(context).show('Link copied');
        },
        child: const Text('Copy link'),
      ),
      TextButton(onPressed: () => Navigator.of(dialog).pop(), child: const Text('Done')),
    ],
  ),
);
