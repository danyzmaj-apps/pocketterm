import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/logo.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/controller.dart';
import 'package:pocketterm_desktop/hosting/hosting_view.dart';
import 'package:pocketterm_desktop/hosting/tailscale.dart';
import 'package:pocketterm_desktop/hosting/vps.dart';
import 'package:pocketterm_desktop/onboarding/commands_view.dart';
import 'package:pocketterm_desktop/onboarding/data_protection.dart';

final Uri _selfHostingGuide = Uri.parse(
  'https://github.com/danyzmaj-apps/pocketterm/blob/main/docs/SELF_HOSTING.md#on-my-own-server',
);

final Uri _serverNeeds = Uri.parse(
  'https://github.com/danyzmaj-apps/pocketterm/blob/main/apps/pocketterm-server/README.md#what-it-needs',
);

/// The first-run setup's screens. Where it was left is kept
/// ([AppController.setupStep]) and it opens there again.
enum SetupStep {
  /// On this computer, or on my own server.
  choose,

  /// The Tailscale checklist, then Start.
  thisComputer,

  /// Do you already have a PocketTerm server?
  ownServer,

  /// Yes: its setup link.
  haveServer,

  /// Not yet: its address, the commands for it, live checks, its setup link.
  newServer,
}

/// First run: where this computer's PocketTerm server runs. **On this
/// computer**: the server built into the app, reached through Tailscale
/// (lib/hosting/), after a checklist that follows Tailscale as the person
/// sets it up. **On my own server**: a VPS, by its setup link, or, without
/// one yet, the commands that set one up, checked live (lib/hosting/vps.dart).
/// Either way, the setup checklist follows sign-in
/// (lib/onboarding/get_ready.dart).
class SetupPage extends StatefulWidget {
  const SetupPage({
    required this.app,
    this.poll = const Duration(seconds: 3),
    this.checks = const ServerChecks(),
    super.key,
  });
  final AppController app;

  /// How often the live checks look again; [Duration.zero]: only once.
  final Duration poll;

  /// What the VPS checks ask the network.
  final ServerChecks checks;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  late SetupStep _step = SetupStep.values.asNameMap()[widget.app.setupStep] ?? SetupStep.choose;

  void _go(SetupStep step) {
    setState(() => _step = step);
    unawaited(widget.app.setSetupStep(step == SetupStep.choose ? null : step.name));
  }

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: SizedBox(
        width: 460,
        child: switch (_step) {
          SetupStep.choose => _choose(),
          SetupStep.thisComputer => ThisComputerSetup(
            app: widget.app,
            poll: widget.poll,
            onBack: () => _go(SetupStep.choose),
            onOwnServer: () => _go(SetupStep.ownServer),
          ),
          SetupStep.ownServer => _ownServer(),
          SetupStep.haveServer => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(
                'Paste your server’s setup link',
                'On the server, in ~/pocketterm, run: sudo docker compose exec server pocketterm-server setup-link. '
                    'A computer of yours that runs PocketTerm’s server has one too, in Settings → Account → Add a '
                    'computer…',
                () => _go(SetupStep.ownServer),
              ),
              SetupLinkForm(app: widget.app, checks: widget.checks),
            ],
          ),
          SetupStep.newServer => NewServerSetup(
            app: widget.app,
            poll: widget.poll,
            checks: widget.checks,
            onBack: () => _go(SetupStep.ownServer),
          ),
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
        title: 'On this computer',
        text:
            'Free, set up in a few clicks. Uses Tailscale, on this computer and your phone. This computer must stay '
            'awake.',
        onTap: () => _go(SetupStep.thisComputer),
      ),
      const SizedBox(height: 12),
      _option(
        key: const ValueKey('setup-own-server'),
        icon: Icons.dns_outlined,
        title: 'On my own server',
        text:
            'A VPS you rent. No Tailscale, and several computers share one server. Your sessions still run here, '
            'so this computer stays awake for them too.',
        onTap: () => _go(SetupStep.ownServer),
      ),
      const SizedBox(height: 18),
      const Explainer(
        key: ValueKey('why-server'),
        title: 'What is a PocketTerm server?',
        child: Text(
          'It introduces your phone to your computers and passes their messages along. It keeps your list of '
          'devices, your computers’ names, pairing codes for 10 minutes and your phones’ push tokens. Your sessions '
          'pass through it only encrypted, so it can’t read them.',
        ),
      ),
      const Explainer(key: ValueKey('why-data'), title: 'How your data is protected', child: DataProtection()),
    ],
  );

  Widget _ownServer() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _header('On my own server', 'Do you already have a PocketTerm server?', () => _go(SetupStep.choose)),
      _option(
        key: const ValueKey('setup-have-server'),
        icon: Icons.link,
        title: 'Yes',
        text: 'Paste its setup link. A link from another computer of yours that runs PocketTerm’s server works too.',
        onTap: () => _go(SetupStep.haveServer),
      ),
      const SizedBox(height: 12),
      _option(
        key: const ValueKey('setup-new-server'),
        icon: Icons.add_circle_outline,
        title: 'Not yet',
        text: 'Set one up on a VPS: you get the commands to copy, and each step is checked as you go.',
        onTap: () => _go(SetupStep.newServer),
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          const Expanded(
            child: Text(
              'Already run your own servers? See what the PocketTerm server needs.',
              style: TextStyle(fontSize: 12.5, color: C.dim, height: 1.45),
            ),
          ),
          TextButton(
            key: const ValueKey('setup-server-needs'),
            onPressed: () => openLink(_serverNeeds),
            style: TextButton.styleFrom(foregroundColor: C.dim2),
            child: const Text('Open link'),
          ),
        ],
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
        key: const ValueKey('setup-back'),
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
    const SizedBox(height: 18),
  ],
);

const _errorColor = Color(0xFFFCA5A5);

/// Where one step of a live checklist stands.
enum CheckState {
  /// Not known yet: the first look is on its way.
  looking,

  /// Done: one line, nothing to do.
  done,

  /// The step to do now: what and how, with its buttons.
  now,

  /// Waits for an earlier one.
  later,
}

/// One step of a live checklist: done ones collapse to a line, the one to
/// do now shows its [note] and [actions], later ones only their title.
class SetupCheck extends StatelessWidget {
  const SetupCheck({required this.state, required this.title, this.note, this.actions = const [], super.key});
  final CheckState state;
  final String title;
  final String? note;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final now = state == CheckState.now;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: SizedBox.square(
              dimension: 18,
              child: switch (state) {
                CheckState.looking => const Padding(
                  padding: EdgeInsets.all(3),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                CheckState.done => const Icon(Icons.check_circle, size: 18, color: C.ok),
                CheckState.now => const Icon(Icons.arrow_forward, size: 18, color: C.warn),
                CheckState.later => const Icon(Icons.radio_button_unchecked, size: 18, color: C.dim2),
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: now ? FontWeight.w600 : FontWeight.normal,
                    color: switch (state) {
                      CheckState.done || CheckState.now => C.text,
                      CheckState.looking || CheckState.later => C.dim2,
                    },
                  ),
                ),
                if (now && note != null)
                  Text(note!, style: const TextStyle(fontSize: 12.5, color: C.dim, height: 1.45)),
                if (now && actions.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A question with its answer folded away ("What is Tailscale?"): one tap
/// shows [child].
class Explainer extends StatefulWidget {
  const Explainer({required this.title, required this.child, super.key});
  final String title;
  final Widget child;

  @override
  State<Explainer> createState() => _ExplainerState();
}

class _ExplainerState extends State<Explainer> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 18, color: C.accent),
              const SizedBox(width: 6),
              Text(widget.title, style: const TextStyle(fontSize: 13, color: C.accent)),
            ],
          ),
        ),
      ),
      if (_open)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 0, 10),
          child: DefaultTextStyle.merge(
            style: const TextStyle(fontSize: 12.5, color: C.dim, height: 1.45),
            child: widget.child,
          ),
        ),
    ],
  );
}

/// A note in a box: what the person must not miss.
Widget _notice(String text, {IconData icon = Icons.info_outline, Key? key}) => Container(
  key: key,
  padding: const EdgeInsets.all(12),
  decoration: BoxDecoration(
    color: C.field,
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: C.line2),
  ),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 16, color: C.accent),
      const SizedBox(width: 10),
      Expanded(
        child: Text(text, style: const TextStyle(fontSize: 12.5, color: C.dim, height: 1.45)),
      ),
    ],
  ),
);

/// On this computer: a checklist that follows Tailscale as it's set up,
/// looking again every [poll]: installed, running, signed in, HTTPS
/// certificates on, port 443 free for PocketTerm. Each step shows only its
/// own action; then Start runs the built-in server and signs this computer
/// in to it.
class ThisComputerSetup extends StatefulWidget {
  const ThisComputerSetup({
    required this.app,
    required this.onBack,
    this.onOwnServer,
    this.poll = const Duration(seconds: 3),
    super.key,
  });
  final AppController app;
  final VoidCallback onBack;

  /// A tailnet whose HTTPS only its admin turns on (a work one): the VPS
  /// way instead.
  final VoidCallback? onOwnServer;
  final Duration poll;

  @override
  State<ThisComputerSetup> createState() => _ThisComputerSetupState();
}

class _ThisComputerSetupState extends State<ThisComputerSetup> {
  TailscaleStatus? _status;

  /// What already serves on port 443 of this computer's Tailscale name;
  /// null while nothing else does (or not asked yet).
  String? _taken;

  /// `tailscale serve status` didn't say what serves on port 443.
  bool _unreadable = false;
  Timer? _timer;
  bool _busy = false;
  bool _askingHttps = false;
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
    final ts = widget.app.tailscale;
    final status = await ts.status();
    final ready = status.state == TailscaleState.running && status.https && status.dnsName != null;
    final serving = ready ? await ts.port443(widget.app.ownServerPorts) : null;
    if (mounted) {
      setState(() {
        _status = status;
        _taken = serving is ServingElsewhere ? serving.what : null;
        _unreadable = serving is ServingUnknown;
      });
    }
  }

  Future<void> _turnOnHttps() async {
    setState(() => _askingHttps = true);
    final link = await widget.app.tailscale.enableHttpsLink();
    openLink(link);
    if (mounted) setState(() => _askingHttps = false);
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
    final ts = widget.app.tailscale;
    final done = s == null
        ? null
        : [
            s.state != TailscaleState.missing,
            s.state == TailscaleState.loggedOut || s.state == TailscaleState.running,
            s.state == TailscaleState.running,
            s.state == TailscaleState.running && s.https && s.dnsName != null,
            s.state == TailscaleState.running && s.https && s.dnsName != null && _taken == null && !_unreadable,
          ];
    final commands = widget.app.commands;
    final current = done?.indexOf(false) ?? -1;
    final allDone = done != null && current == -1;
    CheckState state(int i) => switch (done) {
      null => i == 0 ? CheckState.looking : CheckState.later,
      final d when d[i] && (current == -1 || i < current) => CheckState.done,
      _ when i == current => CheckState.now,
      _ => CheckState.later,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(
          'On this computer',
          'PocketTerm runs your server here. Tailscale gives it a private HTTPS address that only your own devices '
              'reach, at home or away. This list checks itself as you go.',
          widget.onBack,
        ),
        const Explainer(
          key: ValueKey('why-tailscale'),
          title: 'What is Tailscale, and why?',
          child: Text(
            'Tailscale makes a private network between your own devices, wherever they are. Your phone reaches this '
            'computer through it, and nothing on the internet can. Tailscale sees which of your devices connect and '
            'when; PocketTerm’s messages are encrypted, so not what they say.',
          ),
        ),
        const SizedBox(height: 8),
        SetupCheck(
          key: const ValueKey('check-installed'),
          state: state(0),
          title: state(0) == CheckState.done ? 'Tailscale is installed' : 'Install Tailscale',
          note:
              'Tailscale’s Personal plan is free (up to 3 users, 100 devices). Sign in with a personal Google, Apple, '
              'GitHub or Microsoft account; a work email domain may start a paid business trial instead.',
          actions: [
            if (commands.brew != null) ...[
              ConfirmedCommand(
                commands: commands,
                label: 'Install Tailscale',
                argv: const ['brew', 'install', '--cask', 'tailscale-app'],
                what: 'Homebrew downloads Tailscale’s app from Tailscale and installs it. Then open it from here.',
                password: 'Homebrew is installing Tailscale for PocketTerm. Enter your Mac password to allow it.',
                onDone: () => unawaited(_look()),
              ),
              smallButton('Download instead', () => openLink(Tailscale.download)),
            ] else if (commands.winget != null) ...[
              ConfirmedCommand(
                commands: commands,
                label: 'Install Tailscale',
                argv: Tailscale.wingetInstall,
                what:
                    'winget, Windows’ own installer, downloads Tailscale from Tailscale and installs it. Windows asks '
                    'you to allow it. Then open Tailscale from here.',
                onDone: () => unawaited(_look()),
              ),
              smallButton('Download instead', () => openLink(Tailscale.windowsDownload)),
            ] else
              smallButton('Install Tailscale', () => openLink(Tailscale.download)),
          ],
        ),
        SetupCheck(
          key: const ValueKey('check-running'),
          state: state(1),
          title: state(1) == CheckState.done ? 'Tailscale is running' : 'Start Tailscale',
          note: 'Open Tailscale and switch it on.',
          actions: [smallButton('Open Tailscale', () => unawaited(ts.open()))],
        ),
        SetupCheck(
          key: const ValueKey('check-signed-in'),
          state: state(2),
          title: state(2) == CheckState.done ? 'Signed in to Tailscale' : 'Sign in to Tailscale',
          note: 'Any account works: Google, GitHub, Microsoft or Apple. Use the same one on your phone.',
          actions: [smallButton('Open Tailscale to sign in', () => unawaited(ts.open()))],
        ),
        SetupCheck(
          key: const ValueKey('check-https'),
          state: state(3),
          title: state(3) == CheckState.done ? 'HTTPS certificates are on' : 'Turn on HTTPS certificates',
          note:
              'On the Tailscale page that opens, turn on HTTPS (and MagicDNS, if it asks). Your phone then gets a '
              'secure address for this computer. On a work tailnet only its admin can: ask them, or run your server '
              'on a VPS instead.',
          actions: [
            smallButton(
              _askingHttps ? 'Opening…' : 'Turn on HTTPS…',
              _askingHttps ? null : () => unawaited(_turnOnHttps()),
              key: const ValueKey('setup-turn-on-https'),
            ),
            if (widget.onOwnServer case final go?)
              smallButton('Use my own server instead', go, key: const ValueKey('setup-https-own-server')),
          ],
        ),
        SetupCheck(
          key: const ValueKey('check-serve-free'),
          state: state(4),
          title: switch (state(4)) {
            CheckState.done => 'Tailscale’s HTTPS port is free for PocketTerm',
            CheckState.now => 'Free Tailscale’s HTTPS port (443)',
            _ => 'Tailscale’s HTTPS port (443) for PocketTerm',
          },
          note: _taken != null
              ? 'Tailscale already serves $_taken there. PocketTerm needs that port and won’t replace it: remove it '
                    'with tailscale serve --https=443 off, or move it to another port (tailscale serve --https=8443 …). '
                    'This list checks again by itself.'
              : _unreadable
              ? 'PocketTerm couldn’t read Tailscale’s Serve settings, so it doesn’t know yet whether that port is '
                    'free. This list checks again by itself.'
              : null,
        ),
        const SizedBox(height: 14),
        _notice(phoneTailscaleNote, icon: Icons.phone_iphone, key: const ValueKey('setup-phone-tailscale')),
        const SizedBox(height: 18),
        FilledButton(
          key: const ValueKey('setup-start-server'),
          onPressed: allDone && !_busy ? () => unawaited(_start()) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Start'),
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
      ],
    );
  }
}

/// What's wrong with [text] as a computer's setup link, for the person;
/// null when it is one (`pocketterm://setup?url=<https url>&setup=<token>`).
String? setupLinkProblem(String text) {
  final link = Uri.tryParse(text.trim());
  if (link == null || link.scheme != 'pocketterm' || link.host != 'setup' || link.queryParameters['url'] == null) {
    return 'That isn’t a setup link. It starts with pocketterm://setup?url= : copy the whole line setup-link '
        'printed.';
  }
  if (Backend.parse(link.queryParameters['url']!).error case final error?) {
    return 'The server address in that link doesn’t work. $error';
  }
  if (Backend.setupToken(link) != null) return null;
  if (Backend.pairingCode(link) != null) {
    return 'That link signs in a phone, not a computer. Use the server’s setup link: on the server, run '
        'sudo docker compose exec server pocketterm-server setup-link.';
  }
  return 'That link has no setup token: copy the whole line setup-link printed.';
}

/// A setup link, checked as it's pasted (a link at all, a computer's, its
/// server answering, this computer's clock against the server's), then
/// redeemed by Connect.
class SetupLinkForm extends StatefulWidget {
  const SetupLinkForm({required this.app, this.checks = const ServerChecks(), this.clock = true, super.key});
  final AppController app;

  /// What asks the pasted link's server for its health.
  final ServerChecks checks;

  /// Says when this computer's clock is off the server's; false where the
  /// screen already says so.
  final bool clock;

  @override
  State<SetupLinkForm> createState() => _SetupLinkFormState();
}

class _SetupLinkFormState extends State<SetupLinkForm> {
  final _link = TextEditingController();
  bool _busy = false;
  String? _error;

  /// The pasted link's server: null while not asked, `''` while asking.
  String? _health;

  /// This computer's clock is too far off the server's ([Backend.clockWarning]).
  String? _clock;
  int _asked = 0;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  void _changed(String text) {
    final asked = ++_asked;
    final problem = text.trim().isEmpty ? null : setupLinkProblem(text);
    setState(() {
      _error = problem;
      _health = null;
      _clock = null;
    });
    if (text.trim().isEmpty || problem != null) return;
    final backend = Backend.fromLink(Uri.parse(text.trim()))!;
    setState(() => _health = '');
    unawaited(
      widget.checks.answers(backend).then((h) {
        if (!mounted || asked != _asked) return;
        setState(() {
          _health = h.error == null ? '${backend.host} answers' : null;
          _error = h.error;
          _clock = Backend.clockWarning(h.clockOffset);
        });
      }),
    );
  }

  Future<void> _connect() async {
    if (setupLinkProblem(_link.text) case final problem?) return setState(() => _error = problem);
    _asked++;
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = widget.app;
    await app.connectLink(Uri.parse(_link.text.trim()));
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
      TextField(
        key: const ValueKey('setup-link'),
        controller: _link,
        enabled: !_busy,
        autocorrect: false,
        keyboardType: TextInputType.url,
        decoration: setupField('pocketterm://setup?url=…&setup=…'),
        onChanged: _changed,
        onSubmitted: (_) => unawaited(_connect()),
      ),
      if (_health != null && _error == null) ...[
        const SizedBox(height: 8),
        Row(
          key: const ValueKey('setup-link-health'),
          children: [
            SizedBox.square(
              dimension: 14,
              child: _health!.isEmpty
                  ? const Padding(padding: EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check, size: 14, color: C.ok),
            ),
            const SizedBox(width: 8),
            Text(
              _health!.isEmpty ? 'Asking the server…' : _health!,
              style: const TextStyle(fontSize: 12, color: C.dim),
            ),
          ],
        ),
      ],
      if (_clock case final clock? when widget.clock) ...[
        const SizedBox(height: 10),
        _notice(clock, icon: Icons.schedule, key: const ValueKey('setup-link-clock')),
      ],
      const SizedBox(height: 14),
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
          style: const TextStyle(fontSize: 12, color: _errorColor, height: 1.4),
        ),
      ],
    ],
  );
}

/// Not yet: the VPS's address, the commands that set the server up there
/// (lib/hosting/vps.dart), and checks that follow it live (the name
/// resolves, HTTPS answers, the server is healthy); once it is, its setup
/// link.
class NewServerSetup extends StatefulWidget {
  const NewServerSetup({
    required this.app,
    required this.onBack,
    this.poll = const Duration(seconds: 3),
    this.checks = const ServerChecks(),
    super.key,
  });
  final AppController app;
  final VoidCallback onBack;
  final Duration poll;
  final ServerChecks checks;

  @override
  State<NewServerSetup> createState() => _NewServerSetupState();
}

class _NewServerSetupState extends State<NewServerSetup> {
  late final _address = TextEditingController(text: widget.app.setupAddress);
  late ServerAddress _parsed = ServerAddress.parse(_address.text);
  Timer? _timer;

  /// What the checks found for [_checked]: null until known.
  String? _checked;
  bool? _resolves;
  bool? _https;
  bool? _healthy;
  String? _healthProblem;

  /// This computer's clock is too far off the server's ([Backend.clockWarning]).
  String? _clock;
  bool _looking = false;

  /// This app's version: the commands fetch the compose file of its release.
  String? _version;

  @override
  void initState() {
    super.initState();
    unawaited(PackageInfo.fromPlatform().then((p) => mounted ? setState(() => _version = p.version) : null));
    unawaited(_look());
    if (widget.poll > Duration.zero) _timer = Timer.periodic(widget.poll, (_) => unawaited(_look()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _address.dispose();
    super.dispose();
  }

  void _changed(String text) {
    unawaited(widget.app.setSetupAddress(text));
    final parsed = ServerAddress.parse(text);
    setState(() => _parsed = parsed);
    if (parsed.domain != _checked) unawaited(_look());
  }

  /// One round of checks on the address as it is now, each only once the
  /// one before passed. A healthy server isn't looked at again.
  Future<void> _look() async {
    final domain = _parsed.domain;
    if (domain != _checked) {
      setState(() {
        _checked = domain;
        _resolves = _https = _healthy = null;
        _healthProblem = _clock = null;
      });
    }
    if (domain == null || (_healthy ?? false) || _looking) return;
    _looking = true;
    try {
      final checks = widget.checks;
      final resolves = await checks.resolves(domain);
      final https = resolves && await checks.https(domain);
      final health = https ? await checks.health(domain) : null;
      if (!mounted || _checked != domain) return;
      setState(() {
        _resolves = resolves;
        _https = resolves ? https : null;
        _healthy = health == null ? null : health.error == null;
        _healthProblem = health?.error;
        _clock = Backend.clockWarning(health?.clockOffset);
      });
    } finally {
      _looking = false;
    }
    // The address changed while this round ran: look at the new one.
    if (mounted && _checked != _parsed.domain) unawaited(_look());
  }

  @override
  Widget build(BuildContext context) {
    final domain = _parsed.domain;
    final typed = _address.text.trim().isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(
          'Set up a server on a VPS',
          'Rent a small Linux VPS from any provider (1 GB of memory is plenty) and open a terminal on it with SSH. '
              'What’s its address?',
          widget.onBack,
        ),
        const Explainer(
          key: ValueKey('why-docker'),
          title: 'What do Docker and Caddy do?',
          child: Text(
            'Docker runs the PocketTerm server in a container, so nothing else on the VPS changes. Caddy runs next to '
            'it: it answers on ports 80 and 443 and gets a free HTTPS certificate from Let’s Encrypt, renewing it on '
            'its own. The server keeps your device list, computer names, pairing codes and push tokens, and passes '
            'your encrypted messages along.',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('setup-address'),
          controller: _address,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: setupField('203.0.113.7 or pocketterm.example.com'),
          onChanged: _changed,
        ),
        const SizedBox(height: 8),
        if (typed && _parsed.error != null)
          Text(
            _parsed.error!,
            key: const ValueKey('setup-address-error'),
            style: const TextStyle(fontSize: 12, color: _errorColor, height: 1.4),
          ),
        if (domain != null) ...[
          Text.rich(
            key: const ValueKey('setup-domain'),
            TextSpan(
              children: [
                const TextSpan(text: 'Your server’s name: '),
                TextSpan(
                  text: domain,
                  style: const TextStyle(color: C.text, fontWeight: FontWeight.w600),
                ),
                TextSpan(
                  text: domain.endsWith('.sslip.io')
                      ? ' (sslip.io turns the IP address into a name, so the server gets an HTTPS certificate).'
                      : '. Point its DNS A record at the server first.',
                ),
              ],
            ),
            style: const TextStyle(fontSize: 12, color: C.dim, height: 1.45),
          ),
          const SizedBox(height: 16),
          _notice(
            'Ports 80 and 443 must be open to the internet: check your provider’s firewall. The server gets its '
            'certificate from Let’s Encrypt, which checks port 80.',
            icon: Icons.shield_outlined,
          ),
          const SizedBox(height: 16),
          Text(
            'Run these on the server, not here. To get there, type this in ${Platform.isWindows ? 'PowerShell' : 'Terminal'} '
            '(some providers sign you in as ubuntu or debian instead of root):',
            style: const TextStyle(fontSize: 12.5, color: C.dim, height: 1.45),
          ),
          const SizedBox(height: 6),
          CopyCommand(_parsed.ssh!, key: const ValueKey('setup-ssh')),
          const SizedBox(height: 16),
          for (final (i, c) in (_version == null ? const <VpsCommand>[] : vpsCommands(domain, _version!)).indexed) ...[
            Text('${i + 1}. ${c.title}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            CopyCommand(c.command, key: ValueKey('setup-command-$i')),
            const SizedBox(height: 12),
          ],
          const Text('Signed in as root? You can leave out sudo.', style: TextStyle(fontSize: 11.5, color: C.dim2)),
          const SizedBox(height: 16),
          Text('Checking $domain', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          ..._checks(domain),
          if (_clock case final clock?) ...[
            const SizedBox(height: 10),
            _notice(clock, icon: Icons.schedule, key: const ValueKey('setup-clock')),
          ],
          if (_healthy ?? false) ...[
            const SizedBox(height: 14),
            const Text(
              'Your server is up. Paste the setup link step 4 printed:',
              style: TextStyle(fontSize: 13, color: C.dim, height: 1.45),
            ),
            const SizedBox(height: 10),
            SetupLinkForm(app: widget.app, checks: widget.checks, clock: false),
          ],
        ],
        const SizedBox(height: 14),
        TextButton(
          onPressed: () => openLink(_selfHostingGuide),
          style: TextButton.styleFrom(foregroundColor: C.dim2),
          child: const Text('The full guide, with other ways to run it'),
        ),
      ],
    );
  }

  List<Widget> _checks(String domain) {
    CheckState state({required bool? ok, required bool reached}) => switch (ok) {
      true => CheckState.done,
      false => CheckState.now,
      null when !reached => CheckState.later,
      null => CheckState.looking,
    };
    final sslip = domain.endsWith('.sslip.io');
    return [
      SetupCheck(
        key: const ValueKey('check-dns'),
        state: state(ok: _resolves, reached: true),
        title: '$domain resolves',
        note: sslip
            ? 'sslip.io doesn’t answer. Check this computer’s internet connection.'
            : 'Not yet. Add an A record for $domain with your server’s IP address; it can take a few minutes.',
      ),
      SetupCheck(
        key: const ValueKey('check-https'),
        state: state(ok: _https, reached: _resolves ?? false),
        title: 'HTTPS answers',
        note:
            'Not yet. Run steps 1 to 3. Getting the certificate takes a minute after the server starts; if it stays '
            'here, open ports 80 and 443.',
      ),
      SetupCheck(
        key: const ValueKey('check-health'),
        state: state(ok: _healthy, reached: _https ?? false),
        title: 'The PocketTerm server answers',
        note: _healthProblem ?? 'Not yet.',
      ),
    ];
  }
}
