import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/account.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/connect.dart' show ConfirmLink;
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/controller.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_desktop/onboarding/pair.dart';
import 'package:pocketterm_desktop/onboarding/reviewer.dart';
import 'package:pocketterm_desktop/setup_page.dart';
import 'package:pocketterm_desktop/terminal_fixes.dart';
import 'package:pocketterm_desktop/wezterm_setup.dart';
import 'package:url_launcher/url_launcher.dart';

/// The window: the setup wizard, then sign-in, then Settings. Closing it
/// only hides it (lib/desktop_host.dart); the app keeps running.
class MainWindow extends StatelessWidget {
  const MainWindow({required this.app, this.integrations, super.key});
  final AppController app;

  /// Settings' [SettingsPage.integrations].
  final Integrations? integrations;

  @override
  Widget build(BuildContext context) {
    final signedIn = app.user != null;
    return ColoredBox(
      color: C.win,
      child: Stack(
        children: [
          if (app.backend == null)
            SetupPage(
              session: app,
              wezterm: () => WezTermSetup.forHost(app.terminals.wezterm),
              macTerminals: Platform.isMacOS ? app.terminals : null,
            )
          else if (!signedIn)
            SignInPage(session: app)
          else
            SettingsPage(app: app, integrations: integrations),
          Positioned(
            top: 0,
            left: 80,
            right: 0,
            // The drag strip for the transparent title bar.
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => unawaited(app.host.startDrag()),
              child: const SizedBox(height: 28),
            ),
          ),
          if (!signedIn && app.linkToConfirm != null)
            ColoredBox(
              color: Colors.black54,
              child: Center(
                child: SizedBox(
                  width: 400,
                  child: ConfirmLink(session: app, link: app.linkToConfirm!),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ==================================================================== settings

/// Settings, the whole window while signed in.
class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.app, this.integrations, super.key});
  final AppController app;

  /// Installs the coding agents' PocketTerm integrations; the real ones if null.
  final Integrations? integrations;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// Why Launch at login didn't change, when the system refused.
  String? _launchError;

  /// The terminals as the bridge would find them, and their windows.
  List<TermStatus>? _terminals;
  int _windowCount = 0;

  /// What a one-click fix did, by terminal id.
  final _fixed = <String, String>{};

  /// The chosen coding agent's PocketTerm integration, and how installing it went.
  IntegrationState? _integration;
  String? _installNote;
  bool _installFailed = false;

  /// Claude Code has mods off, so its installed plugin doesn't run
  /// ([Integrations.claudeModsOff]).
  bool _modsOff = false;
  bool _installing = false;
  late final Integrations _integrations = widget.integrations ?? Integrations();

  /// Windows: installing WezTerm from its row; null elsewhere.
  late final WezTermSetup? _wezterm = WezTermSetup.forHost(app.terminals.wezterm)?..addListener(_weztermChanged);

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    _check();
    app.mainShown.addListener(_check);
  }

  @override
  void dispose() {
    app.mainShown.removeListener(_check);
    _wezterm?.dispose();
    super.dispose();
  }

  /// Its progress shows on its row; once it's in, the row says so.
  void _weztermChanged() {
    if (!mounted) return;
    setState(() {});
    if (_wezterm!.installed) unawaited(_checkTerminals());
  }

  /// What the system, the terminals and the agent say now: on first build and
  /// each time the (hidden, never rebuilt) window is shown again.
  void _check() {
    unawaited(app.refreshLaunchAtLogin());
    unawaited(_checkTerminals());
    unawaited(_checkIntegration());
  }

  Future<void> _checkTerminals() async {
    final statuses = await app.terminals.statuses();
    var windows = 0;
    try {
      windows = (await app.terminals.windows()).length;
    } on TerminalException {
      // Counted as none.
    }
    if (!mounted) return;
    setState(() {
      _terminals = statuses;
      _windowCount = windows;
    });
  }

  /// Settings' one click for [s]: [fixTerminal] on the Mac, or WezTerm's
  /// installer fetched and opened (Windows, [WezTermSetup]).
  Future<void> _fix(TermStatus s) async {
    if (s.fix == TermFix.install) {
      unawaited(_wezterm?.install());
      return;
    }
    _fixed[s.id] = await fixTerminal(app.terminals, s);
    if (mounted) setState(() {});
    await _checkTerminals();
  }

  /// A terminal's row: how it stands, and its one-click fix if it has one.
  Widget _terminalRow(TermStatus s) {
    final state = switch (s.state) {
      TermState.ready => 'Ready',
      TermState.limited => 'Limited',
      TermState.setup => 'Needs setup',
      TermState.idle => 'Not running',
      TermState.missing => 'Not installed',
    };
    // Only tmux, and a terminal with an install fix, show while missing, with how to get it.
    final installing = s.fix == TermFix.install ? _wezterm?.note : null;
    final note =
        installing ??
        _fixed[s.id] ??
        (s.state == TermState.missing || s.note.isEmpty || s.note == state
            ? (s.note.isEmpty ? state : s.note)
            : '$state · ${s.note}');
    return _row(
      label: s.label,
      sub: note,
      subError: (s.state == TermState.setup && _fixed[s.id] == null) || (installing != null && _wezterm!.error != null),
      trailing: switch (s.fix) {
        TermFix.kittyConfig when _fixed[s.id] == null => _button('Set up', () => unawaited(_fix(s))),
        TermFix.automation => _button('Allow…', () => unawaited(_fix(s))),
        TermFix.install when _wezterm == null => const SizedBox.shrink(),
        TermFix.install when _wezterm!.state == WezTermSetupState.missing => _button(
          'Install',
          () => unawaited(_fix(s)),
        ),
        TermFix.install => const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        _ => const SizedBox.shrink(),
      },
    );
  }

  /// Settings → Project folders → Add folder…: the picked folders join the
  /// list, each once.
  Future<void> _addFolders() async {
    final picked = await app.host.pickFolders();
    if (picked.isEmpty) return;
    await app.setProjectRoots({...app.projectRoots, ...picked}.toList());
  }

  /// [p] with the home folder as `~`.
  String _tilde(String p) {
    final home = app.terminals.home;
    if (p == home) return '~';
    return p.startsWith('$home/') ? '~${p.substring(home.length)}' : p;
  }

  /// Settings → Terminals → Project folders.
  Widget _projectFolders() {
    final roots = app.projectRoots;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Project folders', style: TextStyle(fontSize: 13)),
          const Text(
            'Your phone lists the git repositories in these (up to three levels deep) and makes new projects here',
            style: TextStyle(fontSize: 11, color: C.dim),
          ),
          const SizedBox(height: 8),
          if (roots.isEmpty)
            const Text(
              'None yet · your phone can still open any path you type',
              style: TextStyle(fontSize: 11, color: C.dim),
            ),
          for (final root in roots)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(child: Text(_tilde(root), style: const TextStyle(fontSize: 12))),
                  _button(
                    'Remove',
                    () => unawaited(
                      app.setProjectRoots([
                        for (final r in app.projectRoots)
                          if (r != root) r,
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          _button('Add folder…', () => unawaited(_addFolders())),
        ],
      ),
    );
  }

  Future<void> _checkIntegration() async {
    final agent = app.codingAgent;
    IntegrationState r;
    var modsOff = false;
    try {
      r = await _integrations.state(agent);
      if (agent == Agent.claude && r.installed) modsOff = await _integrations.claudeModsOff();
    } on Object catch (e) {
      r = (installed: false, current: false, problem: '$e');
    }
    if (mounted && agent == app.codingAgent) {
      setState(() {
        _integration = r;
        _modsOff = modsOff;
      });
    }
  }

  /// What to do while Claude Code has mods off: its rollout switch stays
  /// cached as off until Claude Code, logged in, fetches it again.
  static const _modsOffHint =
      'Claude Code has mods turned off for now: run claude /login, start claude once, '
      'then restart your Claude sessions';

  Future<void> _setAgent(Agent agent) async {
    if (agent == app.codingAgent) return;
    setState(() {
      _integration = _installNote = null;
      _installFailed = _modsOff = false;
    });
    await app.setCodingAgent(agent);
    await _checkIntegration();
  }

  Future<void> _install() async {
    final agent = app.codingAgent;
    setState(() => _installing = true);
    String? error;
    try {
      await _integrations.install(agent);
    } on Object catch (e) {
      error = "Couldn't install: $e";
    }
    if (!mounted) return;
    // Whether it runs: mods may be off.
    if (error == null) await _checkIntegration();
    if (!mounted) return;
    // Settings may have moved on to the other agent meanwhile.
    if (agent != app.codingAgent) return setState(() => _installing = false);
    setState(() {
      _installing = false;
      _installNote =
          error ??
          (_modsOff ? 'Installed · $_modsOffHint' : 'Installed · restart your ${agent.label} sessions to load it');
      _installFailed = error != null || _modsOff;
    });
    if (error != null) await _checkIntegration();
  }

  /// Where a session from the phone opens, and what tmux adds there.
  String get _opensInSub {
    final chosen = app.terminals.apps.where((h) => h.id == app.terminalApp).firstOrNull;
    final where = chosen == null ? 'Auto: the terminal app you used last' : 'Always ${chosen.label}';
    final tmux = _terminals?.where((s) => s.id == 'tmux').firstOrNull;
    if (tmux == null) return where;
    return tmux.state == TermState.missing
        ? '$where · in Terminal and Ghostty your phone can’t press keys or (Ghostty) see the screen: '
              'brew install tmux for full control'
        : '$where · in Terminal and Ghostty they run in tmux, so your phone has full control';
  }

  /// Where the chosen agent's integration stands, for its row.
  String get _integrationSub {
    final s = _integration;
    if (s == null) return 'Checking…';
    if (s.problem case final p?) return p;
    if (!s.installed) return "Not installed · this agent's sessions on your phone need it";
    if (_modsOff) return _modsOffHint;
    return s.current ? 'Installed and up to date' : 'Out of date';
  }

  @override
  Widget build(BuildContext context) => Center(
    // Scrolls in a window too short for it.
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 36, 16, 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(
              child: Text('Settings', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            if (app.updates?.update case final u?)
              _group('UPDATE', [
                _row(
                  label: 'PocketTerm ${u.version} is out',
                  trailing: _button(
                    'Download',
                    () => unawaited(launchUrl(u.url, mode: LaunchMode.externalApplication)),
                  ),
                ),
              ]),
            _group('ACCOUNT', [
              _row(
                leading: Avatar(url: app.avatarUrl, name: app.userName),
                label: app.userName,
                sub: 'Signed in with GitHub',
                trailing: _button('Sign out', () => unawaited(app.signOut()), danger: true),
              ),
              _row(
                label: 'Your server',
                sub: '${app.backend?.host ?? ''} · Scan a code with your phone to connect it',
                trailing: _button('Set up phone…', () => unawaited(showPairingQr(context, app))),
              ),
              _row(
                label: 'Reviewer access',
                sub: 'For App Store / Play review: a code for a separate demo account',
                trailing: _button('Codes…', () => unawaited(showReviewerAccess(context, app))),
              ),
              _row(
                label: 'Delete account',
                sub: 'Removes everything you saved, on every device',
                trailing: _button('Delete…', () async {
                  if (!await confirmDeleteAccount(context)) return;
                  try {
                    await app.deleteAccount();
                  } on Object catch (e) {
                    if (context.mounted) Toaster.of(context).show('Account not deleted: $e');
                  }
                }, danger: true),
              ),
            ]),
            _group('GENERAL', [
              _row(
                label: 'Launch at login',
                sub: _launchError,
                subError: _launchError != null,
                trailing: Switch(
                  value: app.launchAtLogin ?? false,
                  onChanged: app.launchAtLogin == null
                      ? null
                      : (v) => unawaited(
                          app
                              .setLaunchAtLogin(on: v)
                              .then(
                                (_) => mounted ? setState(() => _launchError = null) : null,
                                onError: (Object e) => mounted
                                    ? setState(() => _launchError = e is PlatformException ? e.message : '$e')
                                    : null,
                              ),
                        ),
                ),
              ),
              _row(
                label: 'Terminal from phone',
                sub: !app.terminalOn
                    ? 'Your phone sees and types into your terminals and coding sessions while this computer is awake'
                    : _terminals == null
                    ? 'Looking for terminals…'
                    : '${_count(_windowCount, 'terminal window')} · '
                          '${_count(app.live.sessions.length, 'coding session')} '
                          '· keeps this computer from idle sleep',
                trailing: Switch(
                  value: app.terminalOn,
                  onChanged: (v) {
                    unawaited(app.setTerminal(on: v));
                    unawaited(_checkTerminals());
                  },
                ),
              ),
              _row(
                label: 'Coding agent',
                sub: 'What a new session from your phone starts',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [
                    for (final a in Agent.values)
                      _button(Integrations.name(a), () => unawaited(_setAgent(a)), active: a == app.codingAgent),
                  ],
                ),
              ),
              _row(
                label: 'PocketTerm in ${Integrations.name(app.codingAgent)}',
                sub: _installNote ?? _integrationSub,
                subError: _installNote != null ? _installFailed : _integration?.problem != null || _modsOff,
                trailing: _installing
                    ? _button('Installing…', () {}, active: true)
                    : switch (_integration) {
                        (:final installed, current: false, problem: null) => _button(
                          installed ? 'Update' : 'Install',
                          () => unawaited(_install()),
                        ),
                        _ => const SizedBox.shrink(),
                      },
              ),
            ]),
            _group('TERMINALS', [
              for (final s in _terminals ?? const <TermStatus>[])
                if (s.state != TermState.missing || s.id == 'tmux' || s.fix != null) _terminalRow(s),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('New sessions open in', style: TextStyle(fontSize: 13)),
                    Text(_opensInSub, style: const TextStyle(fontSize: 11, color: C.dim)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _button('Auto', () => unawaited(app.setTerminalApp('auto')), active: app.terminalApp == 'auto'),
                        for (final h in app.terminals.apps)
                          if (_terminals?.any((s) => s.id == h.id && s.state != TermState.missing) ?? false)
                            _button(
                              h.label,
                              () => unawaited(app.setTerminalApp(h.id)),
                              active: app.terminalApp == h.id,
                            ),
                      ],
                    ),
                  ],
                ),
              ),
              _projectFolders(),
            ]),
            const SizedBox(height: 18),
            Align(alignment: Alignment.centerLeft, child: _button('Quit PocketTerm', () => unawaited(app.host.quit()))),
          ],
        ),
      ),
    ),
  );

  /// "1 terminal window", "2 terminal windows".
  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  Widget _group(String title, List<Widget> rows) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: const TextStyle(fontSize: 11, letterSpacing: .6, color: C.dim)),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1B1D23),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: C.line),
          ),
          child: Column(
            children: [
              for (final (i, r) in rows.indexed) ...[if (i > 0) const Divider(height: 1, color: C.line), r],
            ],
          ),
        ),
      ],
    ),
  );

  Widget _row({required String label, required Widget trailing, Widget? leading, String? sub, bool subError = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            if (leading != null) ...[leading, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 13)),
                  if (sub != null)
                    Text(sub, style: TextStyle(fontSize: 11, color: subError ? const Color(0xFFFCA5A5) : C.dim)),
                ],
              ),
            ),
            trailing,
          ],
        ),
      );

  Widget _button(String label, VoidCallback onTap, {bool danger = false, bool active = false}) => Hoverable(
    onTap: onTap,
    builder: (h) => Container(
      constraints: const BoxConstraints(minWidth: 70),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: h ? const Color(0xFF2E313D) : const Color(0xFF262833),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: active ? C.accent : C.line2),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: danger ? const Color(0xFFFCA5A5) : (active ? C.accent : C.text)),
      ),
    ),
  );
}
