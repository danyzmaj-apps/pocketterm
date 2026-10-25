import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketterm_core/native.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';
import 'package:pocketterm_mobile/mobile.dart';

/// After the first sign-in on a server, before anything registers for push:
/// what notifications go through and who runs it, then the person's choice
/// ([MobileSession.setPushEnabled]). The account sheet's Notifications
/// switch changes it later.
class PushConsentPage extends StatefulWidget {
  const PushConsentPage({required this.session, super.key});
  final MobileSession session;

  @override
  State<PushConsentPage> createState() => _PushConsentPageState();
}

class _PushConsentPageState extends State<PushConsentPage> {
  bool _busy = false;

  Future<void> _choose({required bool on}) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final allowed = await widget.session.setPushEnabled(on: on);
    if (on && !allowed) messenger.showSnackBar(pushNotAllowedSnackBar(allowed: widget.session.notificationsAllowed));
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    // The choice stays in reach; what it's about scrolls above it.
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(Icons.notifications_active_outlined, size: 44, color: C.accent),
                      const SizedBox(height: 14),
                      const Text(
                        'Know when a session needs you',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Your computer tells this phone when a coding session finishes or asks something, even '
                        'while PocketTerm is closed.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: C.dim, height: 1.5),
                      ),
                      const SizedBox(height: 20),
                      const PushExplainer(),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton(
                      key: const ValueKey('push-accept'),
                      onPressed: _busy ? null : () => unawaited(_choose(on: true)),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: Text('Turn on notifications'),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextButton(
                      key: const ValueKey('push-not-now'),
                      // Never waits on anything: the way out while Turn on still waits on the phone.
                      onPressed: () => unawaited(_choose(on: false)),
                      child: const Text('Not now'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Turned on, but the phone said no: the system setting is off.
const pushNotAllowed =
    'Notifications are off for PocketTerm in this phone’s Settings. Allow them there, then try again.';

/// Turned on and allowed, but Apple or Google gave this phone no push address
/// (no internet, or their service didn't answer).
const pushNoToken =
    'This phone couldn’t get a notification address from Apple or Google. Check its internet connection, then '
    'try again.';

/// Why turning push on didn't take: the phone's setting is off ([allowed]
/// false: with a way there) or Apple or Google gave no push address.
SnackBar pushNotAllowedSnackBar({bool? allowed}) => allowed == false
    ? SnackBar(
        content: const Text(pushNotAllowed),
        action: SnackBarAction(label: 'Settings', onPressed: () => unawaited(Native.openSettings(notifications: true))),
      )
    : const SnackBar(content: Text(pushNoToken));

/// On here, but turned off since in the phone's Settings: nothing shows.
const pushBlocked =
    'On, but notifications are off for PocketTerm in this phone’s Settings, so none show. Allow them there.';

/// On here, but the server couldn't be reached to take this phone's token.
const pushNotSent =
    'On, but your server could not be reached to register this phone. PocketTerm tries again as soon as it can.';

/// Where notifications go and what each one on the way can see.
class PushExplainer extends StatelessWidget {
  const PushExplainer({super.key});

  @override
  Widget build(BuildContext context) {
    final store = isIos ? 'Apple' : 'Google';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: C.field,
        borderRadius: C.round(12),
        border: Border.all(color: C.line2, width: C.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Point(
            Icons.dns_outlined,
            'Notifications go through PocketTerm’s push relay, run by Danijel Lovric on his server in Germany '
            '(push.danyzmaj.com). It passes encrypted notifications to Apple or Google. It can’t read them and '
            'keeps nothing.',
          ),
          _Point(
            Icons.lock_outline,
            'The relay and $store see an encrypted message, this phone’s push token and when it was sent, never '
            'which computer or session it is about. Your computer encrypts each notification with the key from its '
            'code, and only your phones open it.',
          ),
          _Point(
            isIos ? Icons.lock_clock_outlined : Icons.notifications_outlined,
            isIos
                ? 'When you follow a session, iOS shows its state on the Lock Screen: working, needs you, or finished. '
                      'Apple doesn’t let apps decrypt these updates, so this state travels unencrypted. It never '
                      'includes any text from your sessions, and it carries no names, folders or ids.'
                : 'Sessions you follow in your notifications are encrypted the same way.',
          ),
          const _Point(Icons.toggle_on_outlined, 'Change your mind any time: Account → Notifications.', last: true),
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point(this.icon, this.text, {this.last = false});
  final IconData icon;
  final String text;
  final bool last;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: last ? 0 : 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: C.dim),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(height: 1.45))),
      ],
    ),
  );
}
