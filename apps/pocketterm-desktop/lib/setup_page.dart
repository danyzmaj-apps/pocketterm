import 'package:flutter/material.dart';
import 'package:pocketterm_core/connect.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_desktop/onboarding/flow.dart';
import 'package:pocketterm_desktop/onboarding/wizard.dart';

/// First run: which Supabase project this computer syncs through. PocketTerm
/// has no server of its own; every user runs theirs. The wizard sets one up
/// from scratch (lib/onboarding/); a server that already exists connects with
/// its setup link, or URL and key. Either way, the setup checklist follows
/// sign-in (lib/onboarding/get_ready.dart).
class SetupPage extends StatefulWidget {
  const SetupPage({required this.session, super.key});
  final Session session;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _flow = SetupFlow();
  bool _existing = false;

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_existing) {
      // The wizard's server was checked while it was set up.
      return SetupWizard(
        flow: _flow,
        onConnect: widget.session.connect,
        onExisting: () => setState(() => _existing = true),
      );
    }
    return ConnectServerForm(
      session: widget.session,
      back: (label: '← Set up a new server instead', onPressed: () => setState(() => _existing = false)),
    );
  }
}
