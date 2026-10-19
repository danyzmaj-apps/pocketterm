import 'package:flutter/material.dart';
import 'package:pocketterm_core/connect.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_desktop/onboarding/flow.dart';
import 'package:pocketterm_desktop/onboarding/wizard.dart';
import 'package:pocketterm_desktop/wezterm_setup.dart';

/// First run: which Supabase project this Mac syncs through. PocketTerm has no
/// server of its own; every user runs theirs. The wizard sets one up from
/// scratch (lib/onboarding/); a server that already exists connects with
/// its setup link, or URL and key.
class SetupPage extends StatefulWidget {
  const SetupPage({required this.session, this.wezterm, this.macTerminals, super.key});
  final Session session;

  /// Makes the wizard's WezTerm step (Windows); none if null or it returns null.
  final WezTermSetup? Function()? wezterm;

  /// The Mac's terminals, for the wizard's last step; null elsewhere.
  final Terminals? macTerminals;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _flow = SetupFlow();
  late final WezTermSetup? _wezterm = widget.wezterm?.call();
  bool _existing = false;

  @override
  void dispose() {
    _flow.dispose();
    _wezterm?.dispose();
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
        wezterm: _wezterm,
        macTerminals: widget.macTerminals,
      );
    }
    return ConnectServerForm(
      session: widget.session,
      back: (label: '← Set up a new server instead', onPressed: () => setState(() => _existing = false)),
    );
  }
}
