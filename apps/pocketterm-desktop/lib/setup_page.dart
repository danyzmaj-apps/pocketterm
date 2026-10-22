import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/logo.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/controller.dart';
import 'package:pocketterm_desktop/hosting/hosting_view.dart';
import 'package:pocketterm_desktop/hosting/tailscale.dart';

final Uri _selfHostingGuide = Uri.parse('https://github.com/danyzmaj-apps/pocketterm/blob/main/docs/SELF_HOSTING.md');

/// Where the server runs, as the first-run setup offers it.
enum SetupChoice { thisComputer, ownServer }

/// First run: where this computer's PocketTerm server runs. **This
/// computer**: the server built into the app, reached through Tailscale
/// (lib/hosting/). **Your own server**: one on a VPS, or another computer
/// that runs it, by its setup link. Either way, the setup checklist follows
/// sign-in (lib/onboarding/get_ready.dart).
class SetupPage extends StatefulWidget {
  const SetupPage({required this.app, this.choice, this.poll = const Duration(seconds: 3), super.key});
  final AppController app;

  /// The screen to open on; the two choices if null.
  final SetupChoice? choice;

  /// How often This computer looks at Tailscale again.
  final Duration poll;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  late SetupChoice? _choice = widget.choice;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
      child: SizedBox(
        width: 440,
        child: switch (_choice) {
          null => _choose(),
          SetupChoice.thisComputer => ThisComputerSetup(
            app: widget.app,
            poll: widget.poll,
            onBack: () => setState(() => _choice = null),
          ),
          SetupChoice.ownServer => OwnServerSetup(app: widget.app, onBack: () => setState(() => _choice = null)),
        },
      ),
    ),
  );

  Widget _choose() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Center(child: PocketTermLogo(size: 56)),
      const SizedBox(height: 14),
      const Text(
        'Set up PocketTerm',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text(
        'Your phone reaches this computer through a PocketTerm server. Where should it run?',
        textAlign: TextAlign.center,
        style: TextStyle(color: C.dim, height: 1.45),
      ),
      const SizedBox(height: 22),
      _option(
        key: const ValueKey('setup-this-computer'),
        icon: Icons.laptop_mac,
        title: 'This computer',
        text:
            'PocketTerm runs the server here. Your phone reaches it from anywhere through Tailscale (free). '
            'This computer has to be on for your phone to connect.',
        onTap: () => setState(() => _choice = SetupChoice.thisComputer),
      ),
      const SizedBox(height: 12),
      _option(
        key: const ValueKey('setup-own-server'),
        icon: Icons.dns_outlined,
        title: 'Your own server',
        text:
            'A PocketTerm server on a VPS or another always-on machine, or a computer of yours that already '
            'runs one. Paste its setup link.',
        onTap: () => setState(() => _choice = SetupChoice.ownServer),
      ),
    ],
  );

  Widget _option({
    required Key key,
    required IconData icon,
    required String title,
    required String text,
    required VoidCallback onTap,
  }) => Hoverable(
    key: key,
    onTap: onTap,
    builder: (h) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: h ? const Color(0xFF23252E) : C.field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: h ? C.accent : C.line2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 26, color: C.accent),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                Text(text, style: const TextStyle(fontSize: 12.5, color: C.dim, height: 1.45)),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Icon(Icons.chevron_right, size: 20, color: C.dim2),
          ),
        ],
      ),
    ),
  );
}

/// A screen's heading and its way back.
Widget _header(String title, String text, VoidCallback onBack) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onBack,
        icon: const Icon(Icons.arrow_back, size: 16),
        label: const Text('Back'),
        style: TextButton.styleFrom(foregroundColor: C.dim, visualDensity: VisualDensity.compact),
      ),
    ),
    const SizedBox(height: 8),
    Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
    const SizedBox(height: 8),
    Text(text, style: const TextStyle(color: C.dim, height: 1.45)),
    const SizedBox(height: 20),
  ],
);

const _errorColor = Color(0xFFFCA5A5);

/// This computer: what Tailscale needs (installed, running and signed in,
/// HTTPS on for the tailnet), then one button that starts the built-in
/// server and signs this computer in to it.
class ThisComputerSetup extends StatefulWidget {
  const ThisComputerSetup({required this.app, required this.onBack, this.poll = const Duration(seconds: 3), super.key});
  final AppController app;
  final VoidCallback onBack;
  final Duration poll;

  @override
  State<ThisComputerSetup> createState() => _ThisComputerSetupState();
}

class _ThisComputerSetupState extends State<ThisComputerSetup> {
  TailscaleStatus? _status;
  Timer? _timer;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_look());
    if (widget.poll > Duration.zero) _timer = Timer.periodic(widget.poll, (_) => unawaited(_look()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _look() async {
    final status = await widget.app.tailscale.status();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.startHosting();
    } on Object catch (e) {
      _error = 'The server didn’t start: $e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (widget.app.user == null) _error ??= widget.app.authError;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final installed = s != null && s.state != TailscaleState.missing;
    final running = s?.state == TailscaleState.running;
    final ts = widget.app.tailscale;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(
          'This computer',
          'PocketTerm runs your server on this computer. Tailscale gives it a private HTTPS address that only '
              'your own devices reach, at home or away.',
          widget.onBack,
        ),
        _check(
          s == null ? null : installed,
          'Tailscale is installed',
          action: s != null && !installed ? smallButton('Install Tailscale', () => openLink(Tailscale.download)) : null,
        ),
        _check(s == null ? null : running, switch (s?.state) {
          TailscaleState.loggedOut => 'Tailscale is signed out: sign in',
          TailscaleState.stopped => 'Tailscale is off: switch it on',
          _ => 'Tailscale is on and signed in',
        }, action: installed && !running ? smallButton('Open Tailscale', () => unawaited(ts.open())) : null),
        _check(
          running ? s!.https && s.dnsName != null : (s == null ? null : false),
          'HTTPS is on for your tailnet',
          action: running && !(s!.https && s.dnsName != null)
              ? smallButton('Turn on HTTPS…', () => openLink(Tailscale.adminDns))
              : null,
          note: running && !(s!.https && s.dnsName != null)
              ? 'In the Tailscale admin console under DNS: MagicDNS and HTTPS Certificates.'
              : null,
        ),
        const SizedBox(height: 10),
        const Text(
          'Install Tailscale on your phone too, signed in to the same account.',
          style: TextStyle(fontSize: 12, color: C.dim2, height: 1.4),
        ),
        const SizedBox(height: 18),
        FilledButton(
          key: const ValueKey('setup-start-server'),
          onPressed: running && !_busy ? () => unawaited(_start()) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Start the server'),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: _errorColor),
          ),
        ],
      ],
    );
  }

  /// A check: [ok] null while looking.
  Widget _check(bool? ok, String text, {Widget? action, String? note}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: SizedBox.square(
            dimension: 16,
            child: switch (ok) {
              null => const Padding(padding: EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2)),
              true => const Icon(Icons.check, size: 16, color: C.ok),
              false => const Icon(Icons.radio_button_unchecked, size: 16, color: C.warn),
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Text(text, style: TextStyle(fontSize: 13, color: ok ?? false ? C.text : C.dim)),
              if (note != null) Text(note, style: const TextStyle(fontSize: 11.5, color: C.dim2, height: 1.4)),
            ],
          ),
        ),
        if (action != null) ...[const SizedBox(width: 10), action],
      ],
    ),
  );
}

/// Your own server: its setup link, from `pocketterm-server setup-link` on
/// a VPS, or from a computer that runs the built-in server (Settings → Add a
/// computer…).
class OwnServerSetup extends StatefulWidget {
  const OwnServerSetup({required this.app, required this.onBack, super.key});
  final AppController app;
  final VoidCallback onBack;

  @override
  State<OwnServerSetup> createState() => _OwnServerSetupState();
}

class _OwnServerSetupState extends State<OwnServerSetup> {
  final _link = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final link = Uri.tryParse(_link.text.trim());
    if (link == null || Backend.fromLink(link) == null) {
      return setState(() => _error = 'Paste the whole setup link: it starts with pocketterm://setup?url=');
    }
    if (Backend.setupToken(link) == null) {
      return setState(
        () => _error =
            'That link signs in a phone, not a computer. Use the server’s setup link: run pocketterm-server '
            'setup-link on the server to see it.',
      );
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = widget.app;
    await app.connectLink(link);
    // A link that didn't sign in leaves nothing behind: the form says why.
    if (app.user == null) {
      final why = app.authError ?? 'That setup link didn’t sign this computer in.';
      if (app.backend != null) await app.disconnect();
      _error = why;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _header(
        'Your own server',
        'Paste your server’s setup link. To see it, run pocketterm-server setup-link on the server. A computer of '
            'yours that runs the server has one in Settings → Account → Add a computer…',
        widget.onBack,
      ),
      TextField(
        key: const ValueKey('setup-link'),
        controller: _link,
        enabled: !_busy,
        autocorrect: false,
        keyboardType: TextInputType.url,
        decoration: setupField('pocketterm://setup?url=…&setup=…'),
        onSubmitted: (_) => unawaited(_connect()),
      ),
      const SizedBox(height: 16),
      FilledButton(
        key: const ValueKey('setup-connect'),
        onPressed: _busy ? null : () => unawaited(_connect()),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Connect'),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(
          _error!,
          key: const ValueKey('setup-error'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: _errorColor),
        ),
      ],
      const SizedBox(height: 18),
      TextButton(
        onPressed: () => openLink(_selfHostingGuide),
        style: TextButton.styleFrom(foregroundColor: C.dim2),
        child: const Text('How to run your own server (Docker)'),
      ),
    ],
  );
}
