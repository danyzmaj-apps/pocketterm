import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pocketterm_core/account.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/connect.dart' show ConfirmLink;
import 'package:pocketterm_core/ghostty_config.dart';
import 'package:pocketterm_core/server_client.dart' show Device, DeviceRole;
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/controller.dart';
import 'package:pocketterm_desktop/hosting/built_in_server.dart';
import 'package:pocketterm_desktop/hosting/hosting_view.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_desktop/onboarding/data_protection.dart';
import 'package:pocketterm_desktop/onboarding/get_ready.dart';
import 'package:pocketterm_desktop/onboarding/pair.dart';
import 'package:pocketterm_desktop/onboarding/terminals_card.dart' show ghosttyTmuxWhy;
import 'package:pocketterm_desktop/setup_page.dart';
import 'package:pocketterm_desktop/terminal_fixes.dart';
import 'package:pocketterm_desktop/update_check.dart';
import 'package:pocketterm_desktop/wezterm_setup.dart';
import 'package:url_launcher/url_launcher.dart';

/// The window: the first-run setup, then sign-in, then the setup checklist
/// until it's done, then Settings. Closing it only hides it
/// (lib/desktop_host.dart); the app keeps running.
class MainWindow extends StatelessWidget {
  const MainWindow({required this.app, super.key});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final signedIn = app.user != null;
    return ColoredBox(
      color: C.win,
      child: Stack(
        children: [
          if (app.backend == null)
            SetupPage(app: app)
          else if (!signedIn)
            SignInPage(session: app)
          else if (!app.getReadyDone)
            GetReadyPage(app: app)
          else
            SettingsPage(app: app),
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
          if (signedIn) _Notice(app: app),
        ],
      ),
    );
  }
}

/// What a link said while signed in ([AppController.notices], e.g. one for
/// another server), over whatever page shows, until the person closes it.
class _Notice extends StatefulWidget {
  const _Notice({required this.app});
  final AppController app;

  @override
  State<_Notice> createState() => _NoticeState();
}

class _NoticeState extends State<_Notice> {
  late final StreamSubscription<String> _notices;
  String? _message;

  @override
  void initState() {
    super.initState();
    _notices = widget.app.notices.listen((message) => setState(() => _message = message));
  }

  @override
  void dispose() {
    unawaited(_notices.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = _message;
    if (message == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        key: const ValueKey('link-notice'),
        width: 460,
        margin: const EdgeInsets.only(top: 40),
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        decoration: BoxDecoration(
          color: C.field,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: C.warn),
        ),
        child: Row(
          children: [
            Expanded(child: Text(message, style: const TextStyle(height: 1.4))),
            TextButton(onPressed: () => setState(() => _message = null), child: const Text('OK')),
          ],
        ),
      ),
    );
  }
}

// ==================================================================== settings

/// Settings' tabs.
enum _Tab {
  phone('Phone'),
  agents('Coding agents'),
  terminals('Terminals'),
  account('Account');

  const _Tab(this.label);
  final String label;
}

/// Something that needs the person on this computer: the tab it's on, a few words for the status bar's line,
/// the whole of it for its list, and the button that does it where one can.
typedef _Item = ({_Tab tab, String short, String text, Widget? action});

/// A card in a tab's grid; `wide` ones take a whole row.
typedef _Cell = ({Widget card, bool wide});

/// Settings, the whole window while signed in: a status bar over the tabs (Phone, Coding agents, Terminals,
/// Account), each a grid of cards.
class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.app, super.key});
  final AppController app;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  _Tab _tab = _Tab.phone;

  /// The status bar lists what needs attention.
  bool _showAttention = false;

  /// Why Launch at login didn't change, when the system refused.
  String? _launchError;

  /// The terminals as the bridge would find them, and their windows.
  List<TermStatus>? _terminals;
  int _windowCount = 0;

  /// What a one-click fix said, by terminal id, with the fix it was for and
  /// whether it failed: shown until the terminal's status no longer carries
  /// that fix, then the live status speaks.
  final _fixed = <String, ({TermFix? fix, String note, bool failed})>{};

  /// Agents PocketTerm is going into, and how it went in each since the window was last shown.
  final _installing = <Agent>{};
  final _installNotes = <Agent, ({String text, Color color})>{};

  /// Agent windows no live session claims, as of [_checkTerminals].
  List<TermWindow> _unreported = const [];
  late final StreamSubscription<void> _live;

  /// The agents whose sessions to pick up are listed.
  final _showSessions = <Agent>{};

  /// Windows: installing WezTerm from its card; null elsewhere.
  late final WezTermSetup? _wezterm = WezTermSetup.forHost(app.terminals.wezterm)?..addListener(_weztermChanged);

  /// Ghostty's config, for starting its new windows in tmux; null without
  /// Ghostty (Windows). What it says, as of [_checkTerminals].
  late final GhosttyConfig? _ghosttyConfig = app.terminals.ghostty == null
      ? null
      : GhosttyConfig.standard(home: app.terminals.home);
  GhosttyCommand? _ghosttyCommand;

  /// PocketTerm's Ghostty line was an earlier one's and was made this
  /// one's ([GhosttyConfig.upgrade]) while the app runs: its card says so.
  bool _ghosttyUpgraded = false;

  /// This build's version, for the Account tab's footer; null until known.
  String? _version;

  /// Who is signed in to the server, for the Account tab; null until known.
  List<Device>? _devices;

  /// This computer's clock is too far off its server's (a VPS's, another
  /// computer's): phones drop what it sends ([Backend.clockWarning]).
  String? _clock;

  AppController get app => widget.app;

  void _shown() {
    if (mounted) setState(_installNotes.clear);
    _check();
  }

  @override
  void initState() {
    super.initState();
    _check();
    app.mainShown.addListener(_shown);
    _live = app.live.changes.listen((_) => unawaited(_checkUnreported()));
    unawaited(_readVersion());
  }

  @override
  void dispose() {
    app.mainShown.removeListener(_shown);
    unawaited(_live.cancel());
    _wezterm?.dispose();
    super.dispose();
  }

  Future<void> _readVersion() async {
    try {
      final v = (await PackageInfo.fromPlatform()).version;
      if (mounted) setState(() => _version = v);
    } on Object {
      // Shown without one.
    }
  }

  /// Its progress shows on its card; once it's in, the card says so.
  void _weztermChanged() {
    if (!mounted) return;
    setState(() {});
    if (_wezterm!.installed) unawaited(_checkTerminals());
  }

  /// What the system, the terminals and the agents say now: on first build and
  /// each time the (hidden, never rebuilt) window is shown again.
  void _check() {
    unawaited(app.refreshLaunchAtLogin());
    unawaited(_checkTerminals());
    unawaited(app.checkAgents());
    unawaited(app.checkPhone());
    unawaited(_checkDevices());
    unawaited(_checkClock());
  }

  Future<void> _checkDevices() async {
    try {
      final devices = await app.serverDevices();
      if (mounted) setState(() => _devices = devices);
    } on Object catch (e) {
      debugPrint('PocketTerm: devices not listed: $e');
    }
  }

  /// Whether this computer's clock is far off its server's, while signed
  /// in to one; the server built into this app keeps this computer's own
  /// time.
  Future<void> _checkClock() async {
    final backend = app.backend;
    if (backend == null || app.server == null || app.hosting != null) return;
    final health = await backend.health();
    if (mounted && health.error == null) setState(() => _clock = Backend.clockWarning(health.clockOffset));
  }

  Future<void> _checkTerminals() async {
    final statuses = await app.terminals.statuses();
    final config = _ghosttyConfig;
    final tmux = app.terminals.tmux?.executable;
    var upgraded = false;
    if (config != null && tmux != null) {
      try {
        upgraded = config.upgrade(tmux);
      } on TerminalException catch (e) {
        debugPrint('PocketTerm: Ghostty config not upgraded: ${e.message}');
      }
    }
    final ghosttyCommand = config?.read();
    var windows = const <TermWindow>[];
    try {
      windows = await app.terminals.windows();
    } on TerminalException {
      // Counted as none.
    }
    if (!mounted) return;
    setState(() {
      _terminals = statuses;
      for (final t in statuses) {
        if (_fixed[t.id] case final f? when f.fix != t.fix) _fixed.remove(t.id);
      }
      _ghosttyCommand = ghosttyCommand;
      if (upgraded) _ghosttyUpgraded = true;
      _windowCount = windows.length;
      _unreported = app.unreportedAgentWindows(windows);
    });
  }

  /// A coding session came or went: the agent windows it claims change.
  Future<void> _checkUnreported() async {
    try {
      final windows = await app.terminals.windows();
      if (mounted) setState(() => _unreported = app.unreportedAgentWindows(windows));
    } on TerminalException {
      // As before.
    }
  }

  /// Settings' one click for [s]: [fixTerminal] on the Mac, or WezTerm's
  /// installer fetched and opened (Windows, [WezTermSetup]).
  Future<void> _fix(TermStatus s) async {
    if (s.fix == TermFix.install) {
      unawaited(_wezterm?.install());
      return;
    }
    final (:note, :failed) = await fixTerminal(app.terminals, s);
    _fixed[s.id] = (fix: s.fix, note: note, failed: failed);
    if (mounted) setState(() {});
    await _checkTerminals();
  }

  /// Ghostty's new windows in tmux ([GhosttyConfig.add]), or back to the
  /// shell ([GhosttyConfig.remove]).
  Future<void> _ghosttyTmux({required bool on}) async {
    final config = _ghosttyConfig!;
    final tmux = app.terminals.tmux?.executable;
    try {
      if (on && tmux != null) {
        config.add(tmux);
      } else if (!on) {
        config.remove();
      }
    } on TerminalException catch (e) {
      if (mounted) Toaster.of(context).show(e.message);
    }
    await _checkTerminals();
  }

  /// [s]'s one-click fix, as its card and the status bar offer it.
  Widget _fixButton(TermStatus s) => switch (s.fix) {
    TermFix.kittyConfig when _fixed[s.id] == null || _fixed[s.id]!.failed => _button(
      'Set up',
      () => unawaited(_fix(s)),
      key: ValueKey('settings-fix-${s.id}'),
    ),
    TermFix.automation => _button('Allow…', () => unawaited(_fix(s))),
    TermFix.install when _wezterm == null => const SizedBox.shrink(),
    TermFix.install when _wezterm!.state == WezTermSetupState.missing => _button('Install', () => unawaited(_fix(s))),
    TermFix.install => const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
    _ => const SizedBox.shrink(),
  };

  /// Phone → Project folders → Add folder…: the picked folders join the
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

  /// Installs (or updates) PocketTerm in [agent], from its card or the status bar; its card says how it went.
  Future<void> _install(Agent agent) async {
    setState(() {
      _installing.add(agent);
      _installNotes.remove(agent);
    });
    String? error;
    try {
      await app.installAgent(agent);
    } on Object catch (e) {
      error = 'Couldn’t install PocketTerm in ${Integrations.name(agent)}: $e';
    }
    if (!mounted) return;
    // Whether it runs: mods may be off.
    final modsOff = app.agents?[agent]?.modsOff ?? false;
    setState(() {
      _installing.remove(agent);
      _installNotes[agent] = error != null
          ? (text: error, color: _error)
          : modsOff
          ? (text: 'Installed · ${Integrations.modsOffHint}', color: C.warn)
          : (
              text: switch (agent) {
                Agent.omp => 'Installed · restart your omp sessions to load it (${agent.resume})',
                Agent.claude => 'Installed · type ${agent.pickUp} in open Claude Code sessions to load it',
              },
              color: C.ok,
            );
    });
  }

  /// "1 terminal window", "2 terminal windows".
  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  // ---------------------------------------------------------------- page

  @override
  Widget build(BuildContext context) {
    final checking = app.agents == null || _terminals == null;
    final items = checking ? const <_Item>[] : _attention;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(
              height: 34,
              child: Center(
                child: Text('Settings', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _statusBar(checking: checking, items: items),
                  if (app.updates?.update case final u?) ...[const SizedBox(height: 10), _updateBar(u)],
                  const SizedBox(height: 12),
                  _tabs({for (final i in items) i.tab}),
                ],
              ),
            ),
            Expanded(
              // Scrolls in a window too short for it.
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
                child: KeyedSubtree(
                  key: const ValueKey('settings-content'),
                  child: _grid(switch (_tab) {
                    _Tab.phone => _phoneTab(),
                    _Tab.agents => _agentsTab(),
                    _Tab.terminals => _terminalsTab(),
                    _Tab.account => _accountTab(),
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The tabs, a dot on each with something that needs attention.
  Widget _tabs(Set<_Tab> attention) => Container(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: C.line2)),
    ),
    child: Wrap(
      children: [
        for (final t in _Tab.values)
          Hoverable(
            key: ValueKey('settings-tab-${t.name}'),
            onTap: () => setState(() => _tab = t),
            builder: (h) => Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: t == _tab ? C.accent : Colors.transparent, width: 2)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(t.label, style: TextStyle(fontSize: 13, color: t == _tab || h ? C.text : C.dim)),
                  if (attention.contains(t)) ...[
                    const SizedBox(width: 6),
                    Container(
                      key: ValueKey('settings-tab-dot-${t.name}'),
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(color: C.warn, shape: BoxShape.circle),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    ),
  );

  /// [cells] in two columns, or one in a narrow window.
  Widget _grid(List<_Cell> cells) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 620) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 14,
          children: [for (final c in cells) c.card],
        );
      }
      final rows = <Widget>[];
      for (var i = 0; i < cells.length; i++) {
        final c = cells[i];
        if (c.wide) {
          rows.add(c.card);
          continue;
        }
        final next = i + 1 < cells.length && !cells[i + 1].wide ? cells[++i].card : const SizedBox.shrink();
        rows.add(
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 14,
              children: [
                Expanded(child: c.card),
                Expanded(child: next),
              ],
            ),
          ),
        );
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 14, children: rows);
    },
  );

  static _Cell _half(Widget card) => (card: card, wide: false);
  static _Cell _wide(Widget card) => (card: card, wide: true);

  // ---------------------------------------------------------------- phone

  List<_Cell> _phoneTab() {
    final roots = app.projectRoots;
    return [
      _half(
        _card(
          title: 'Terminal from phone',
          sub: 'Your phone sees and drives this computer’s sessions. Keeps it awake while on.',
          trailing: Switch(
            key: const ValueKey('settings-terminal-from-phone'),
            value: app.terminalOn,
            onChanged: (v) {
              unawaited(app.setTerminal(on: v));
              unawaited(_checkTerminals());
            },
          ),
          body: [
            if (app.terminalOn)
              Text(
                _terminals == null
                    ? 'Looking for terminals…'
                    : '${_count(_windowCount, 'terminal window')} · '
                          '${_count(app.live.sessions.length, 'coding session')}',
                style: _subStyle(C.dim),
              ),
          ],
        ),
      ),
      _half(
        _card(
          title: 'Your phones',
          sub: (app.phoneSignedIn ?? false) ? 'A phone is signed in' : 'No phone yet',
          subColor: app.phoneSignedIn == false ? C.warn : C.dim,
          body: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _button('Add a phone…', () => unawaited(showPairingQr(context, app))),
                _button('Reset key…', () => unawaited(_resetKey()), key: const ValueKey('settings-reset-key')),
              ],
            ),
          ],
        ),
      ),
      _wide(
        _card(
          title: 'Project folders',
          sub:
              'Your phone lists the git repositories in these (up to three levels deep) and starts new projects there.',
          body: [
            if (roots.isEmpty) Text('None yet · your phone can still open any path you type', style: _subStyle(C.dim)),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final root in roots)
                  _chip(
                    _tilde(root),
                    key: ValueKey('settings-folder-$root'),
                    trailing: Icons.close,
                    tooltip: 'Remove',
                    onTap: () => unawaited(
                      app.setProjectRoots([
                        for (final r in app.projectRoots)
                          if (r != root) r,
                      ]),
                    ),
                  ),
                _chip('Add folder…', leading: Icons.add, onTap: () => unawaited(_addFolders())),
              ],
            ),
          ],
        ),
      ),
    ];
  }

  /// A new channel key (after losing a phone): every phone must scan again.
  Future<void> _resetKey() async {
    final reset =
        await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            backgroundColor: C.bar,
            title: const Text('Reset this computer’s key?'),
            content: const Text(
              'Your phones read this computer’s sessions with a key from its code. A new key locks out every phone '
              'that has the old one, including a lost one. Each phone you keep must scan this computer’s code again '
              '(Settings → Phone → Add a phone…). To keep a lost phone off your server too, sign it out under '
              'Settings → Account.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Cancel')),
              TextButton(
                onPressed: () => Navigator.of(dialog).pop(true),
                style: TextButton.styleFrom(foregroundColor: const Color(0xFFFCA5A5)),
                child: const Text('Reset key'),
              ),
            ],
          ),
        ) ??
        false;
    if (!reset) return;
    try {
      await app.resetChannelKey();
    } on Object catch (e) {
      if (mounted) Toaster.of(context).show('Key not reset: $e');
      return;
    }
    if (mounted) Toaster.of(context).show('New key made. Scan this computer’s code on each phone.');
  }

  // ---------------------------------------------------------------- agents

  List<_Cell> _agentsTab() => [
    for (final agent in Agent.values) _half(_agentCard(agent)),
    _wide(
      _card(
        sub:
            'The default agent is what a new session from your phone starts. PocketTerm talks to your phone '
            'through a small add-on inside each agent.',
      ),
    ),
  ];

  /// Where PocketTerm in [agent] stands, for its card.
  ({String text, Color color}) _agentState(Agent agent) {
    if (_installNotes[agent] case final note?) return note;
    final agents = app.agents;
    if (agents == null) return (text: 'Checking…', color: C.dim);
    final check = agents[agent];
    if (check == null) return (text: 'Not found on this computer', color: C.dim);
    if (check.state.problem case final problem?) return (text: problem, color: C.warn);
    return switch (integrationOf(check)) {
      AgentIntegration.installed => (text: 'PocketTerm installed, up to date', color: C.ok),
      AgentIntegration.off => (text: Integrations.modsOffHint, color: C.warn),
      AgentIntegration.outdated => (text: 'PocketTerm here is out of date', color: C.warn),
      AgentIntegration.missing => (text: 'PocketTerm isn’t installed here yet', color: C.warn),
    };
  }

  Widget _agentCard(Agent agent) {
    final check = app.agents?[agent];
    final missing = app.agents != null && check == null;
    final isDefault = agent == app.codingAgent;
    final state = _agentState(agent);
    final action = switch (check) {
      _ when _installing.contains(agent) => _agentButton(agent, ''),
      (state: (:final installed, current: false, problem: null), modsOff: _) => _agentButton(
        agent,
        installed ? 'Update' : 'Install',
      ),
      _ => null,
    };
    final sessions = _unreported.where((w) => w.agent == agent).toList();
    final n = sessions.length;
    final card = _card(
      key: ValueKey('settings-agent-${agent.name}'),
      title: Integrations.name(agent),
      sub: state.text,
      subColor: state.color,
      // Not an empty Row: its spacing would make it narrower than nothing.
      trailing: action == null && !isDefault
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                ?action,
                if (isDefault)
                  Container(
                    key: ValueKey('settings-default-${agent.name}'),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: C.line2),
                    ),
                    child: const Text('Default', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
      body: [
        if (n > 0) ...[
          Text.rich(
            TextSpan(
              text: switch (agent) {
                Agent.omp => '${_count(n, 'session')} opened before PocketTerm: reopen ${n == 1 ? 'it' : 'each'} with ',
                Agent.claude => '${_count(n, 'session')} opened before PocketTerm: type ',
              },
              children: [
                WidgetSpan(alignment: PlaceholderAlignment.middle, child: _mono(agent.pickUp)),
                if (agent == Agent.claude) TextSpan(text: ' in ${n == 1 ? 'it' : 'each'}'),
              ],
            ),
            style: _subStyle(C.warn),
          ),
          _button(
            _showSessions.contains(agent) ? 'Hide sessions' : 'Show sessions',
            () => setState(() {
              if (!_showSessions.remove(agent)) _showSessions.add(agent);
            }),
          ),
          if (_showSessions.contains(agent))
            for (final w in sessions)
              SessionToPickUp(window: w, terminals: app.terminals, key: ValueKey('settings-unreported-${w.key}')),
        ],
        if (!isDefault && !missing)
          _button(
            'Make default',
            () => unawaited(app.setCodingAgent(agent)),
            key: ValueKey('settings-make-default-${agent.name}'),
          ),
      ],
    );
    return missing ? Opacity(opacity: .6, child: card) : card;
  }

  /// [agent]'s Install (or Update) as [label], or that it's going in.
  Widget _agentButton(Agent agent, String label) => _installing.contains(agent)
      ? _button('Installing…', () {}, active: true)
      : _button(label, () => unawaited(_install(agent)), primary: true);

  Widget _mono(String command) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(color: C.win, borderRadius: BorderRadius.circular(5)),
    child: Text(command, style: monoStyle.copyWith(color: C.text)),
  );

  // ---------------------------------------------------------------- terminals

  List<_Cell> _terminalsTab() => [
    _wide(_card(title: 'New sessions open in', sub: _opensInSub, trailing: _terminalAppChoice())),
    for (final s in _terminals ?? const <TermStatus>[])
      if (s.state != TermState.missing || s.id == 'tmux' || s.fix != null) _half(_terminalCard(s)),
  ];

  /// Where a session from the phone opens, and what tmux adds there.
  String get _opensInSub {
    final chosen = app.terminals.apps.where((h) => h.id == app.terminalApp).firstOrNull;
    final where = chosen == null ? 'Auto: the terminal app you used last' : 'Always ${chosen.label}';
    final tmux = _terminals?.where((s) => s.id == 'tmux').firstOrNull;
    if (tmux == null) return where;
    return tmux.state == TermState.missing
        ? '$where · in Ghostty your phone can’t see the screen or answer: '
              'install tmux for full control'
        : '$where · in Ghostty they run in tmux, so your phone has full control';
  }

  /// Auto, or one of the terminal apps found here (and the one chosen, should it be gone).
  Widget _terminalAppChoice() {
    final chosen = app.terminalApp;
    final apps = [
      for (final h in app.terminals.apps)
        if (h.id == chosen || (_terminals?.any((s) => s.id == h.id && s.state != TermState.missing) ?? false)) h,
    ];
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: C.win,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: C.line2),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const ValueKey('settings-terminal-app'),
          value: chosen == 'auto' || apps.any((h) => h.id == chosen) ? chosen : 'auto',
          isDense: true,
          focusColor: Colors.transparent,
          dropdownColor: C.bar,
          borderRadius: BorderRadius.circular(8),
          iconSize: 18,
          // The page's font: a style here replaces the theme's whole.
          style: DefaultTextStyle.of(context).style.copyWith(fontSize: 12.5, color: C.text),
          items: [
            const DropdownMenuItem(value: 'auto', child: Text('Auto')),
            for (final h in apps) DropdownMenuItem(value: h.id, child: Text(h.label)),
          ],
          onChanged: (id) => unawaited(app.setTerminalApp(id!)),
        ),
      ),
    );
  }

  /// A terminal's card: how it stands, and its one-click fix if it has one.
  Widget _terminalCard(TermStatus s) {
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
        _fixed[s.id]?.note ??
        (s.state == TermState.missing || s.note.isEmpty || s.note == state
            ? (s.note.isEmpty ? state : s.note)
            : '$state · ${s.note}');
    final attention = s.state == TermState.setup || (s.fix == TermFix.install && s.state == TermState.missing);
    return _card(
      key: ValueKey('settings-terminal-${s.id}'),
      title: s.label,
      sub: note,
      subColor: installing != null && _wezterm!.error != null
          ? _error
          : attention || s.state == TermState.limited
          ? C.warn
          : s.state == TermState.ready
          ? C.ok
          : C.dim,
      trailing: _fixButton(s),
      body: s.id == 'ghostty' && s.state != TermState.missing ? _ghosttyTmuxBody() : const [],
    );
  }

  /// Ghostty's card: new windows in tmux with one click, where tmux is
  /// installed and the person's config sets no command of its own.
  List<Widget> _ghosttyTmuxBody() {
    final command = _ghosttyCommand;
    final tmux = app.terminals.tmux?.installed ?? false;
    Widget note(String text) => Text(text, style: _subStyle(C.dim));
    return switch (command?.state) {
      GhosttyCommandState.ours => [
        note(
          _ghosttyUpgraded
              ? 'New Ghostty windows open in tmux with a title PocketTerm can match. Open new windows to use it.'
              : 'Open new Ghostty windows to get full control. Windows already open stay as they are.',
        ),
        _button('Remove', () => unawaited(_ghosttyTmux(on: false)), key: const ValueKey('settings-ghostty-tmux')),
      ],
      GhosttyCommandState.theirs when tmux => [
        note(
          'Your Ghostty config already sets command = ${command!.command}, so PocketTerm leaves it alone. '
          'Add tmux to that command yourself for full control.',
        ),
      ],
      GhosttyCommandState.none when tmux => [
        note(ghosttyTmuxWhy),
        _button(
          'Start new windows in tmux',
          () => unawaited(_ghosttyTmux(on: true)),
          key: const ValueKey('settings-ghostty-tmux'),
        ),
      ],
      _ => const [],
    };
  }

  // ---------------------------------------------------------------- account

  List<_Cell> _accountTab() {
    final hosting = app.hosting;
    return [
      _half(
        _card(
          leading: Avatar(name: app.userName, size: 32),
          title: app.userName,
          sub: hosting == null ? 'Signed in to this server' : 'This computer runs your server',
          body: [
            _button('Sign out', () => unawaited(_signOut()), danger: true, key: const ValueKey('settings-sign-out')),
          ],
        ),
      ),
      _half(
        _card(
          key: const ValueKey('settings-server'),
          title: 'Your server',
          sub: [
            // A computer running the server says where in its status below.
            if (hosting == null) app.backend?.host ?? '',
            if (_devices case final d?) _devicesLine(d),
          ].join(' · '),
          body: [
            for (final d in _devices ?? const <Device>[])
              if (d.role == DeviceRole.phone) _phoneRow(d),
            if (hosting != null) ...[
              HostingStatusView(server: hosting),
              if (hosting.state == HostState.ready)
                _button(
                  'Add a computer…',
                  () => unawaited(showAddComputer(context, app.computerSetupLink()!)),
                  key: const ValueKey('settings-add-computer'),
                ),
            ],
          ],
        ),
      ),
      _half(
        _card(
          title: 'Launch at login',
          sub: _launchError ?? 'Start PocketTerm when you log in',
          subColor: _launchError != null ? _error : C.dim,
          trailing: Switch(
            key: const ValueKey('settings-launch-at-login'),
            value: app.launchAtLogin ?? false,
            onChanged: app.launchAtLogin == null
                ? null
                : (v) => unawaited(
                    app
                        .setLaunchAtLogin(on: v)
                        .then(
                          (_) => mounted ? setState(() => _launchError = null) : null,
                          onError: (Object e) =>
                              mounted ? setState(() => _launchError = e is PlatformException ? e.message : '$e') : null,
                        ),
                  ),
          ),
        ),
      ),
      if (app.hostsServer)
        _half(
          _card(
            title: 'Erase this server\u2019s data',
            sub: 'Signs out every computer and phone and deletes what the server keeps',
            body: [
              _button('Erase…', () async {
                final go = await confirmDanger(
                  context,
                  title: 'Erase this server\u2019s data?',
                  body:
                      'Every computer and phone is signed out of this server, and its images and push registrations '
                      'are deleted. This cannot be undone.',
                  action: 'Erase',
                );
                if (!go) return;
                try {
                  await app.eraseServer();
                } on Object catch (e) {
                  if (mounted) Toaster.of(context).show('Not erased: $e');
                }
                unawaited(_checkDevices());
              }, danger: true),
            ],
          ),
        ),
      _wide(
        _card(
          title: 'How your data is protected',
          sub: 'End-to-end encryption, and what your server, Tailscale and the push relay can see',
          trailing: _button(
            'Read…',
            () => unawaited(showDataProtection(context)),
            key: const ValueKey('settings-data-protection'),
          ),
        ),
      ),
      _wide(
        _card(
          sub: _version == null ? 'PocketTerm' : 'PocketTerm $_version',
          trailing: _button('Quit PocketTerm', () => unawaited(app.host.quit())),
        ),
      ),
    ];
  }

  /// "2 computers, 1 phone".
  static String _devicesLine(List<Device> devices) {
    final phones = devices.where((d) => d.role == DeviceRole.phone).length;
    return '${_count(devices.length - phones, 'computer')}, ${_count(phones, 'phone')}';
  }

  /// A phone signed in to the server, with Sign out (a lost one).
  Widget _phoneRow(Device d) {
    final name = d.label.isEmpty ? 'Phone' : d.label;
    return Row(
      key: ValueKey('settings-phone-${d.id}'),
      children: [
        Expanded(child: Text(name, style: _subStyle(C.dim))),
        _button(
          'Sign out…',
          () => unawaited(_signOutPhone(d, name)),
          danger: true,
          key: ValueKey('settings-phone-sign-out-${d.id}'),
        ),
      ],
    );
  }

  /// Signs [d] out of the server, asked first.
  Future<void> _signOutPhone(Device d, String name) async {
    final go = await confirmDanger(
      context,
      title: 'Sign out $name?',
      body:
          'It can no longer reach your server or get its notifications. To use it again, scan this computer’s '
          'code on it (Settings → Phone → Add a phone…).',
      action: 'Sign out',
    );
    if (!go) return;
    try {
      await app.revokeServerDevice(d.id);
    } on Object catch (e) {
      if (mounted) Toaster.of(context).show('Not signed out: $e');
    }
    await _checkDevices();
  }

  /// Signing out of a server this computer runs stops it: asked first.
  Future<void> _signOut() async {
    if (app.hosting != null) {
      final go = await confirmDanger(
        context,
        title: 'Stop your server and sign out?',
        body:
            'This computer runs your server. Signing out stops it, and your phones and other computers can\u2019t '
            'connect until you choose This computer again. What the server keeps stays on this computer.',
        action: 'Sign out',
      );
      if (!go) return;
    }
    await app.signOut();
  }

  // ---------------------------------------------------------------- status

  /// What needs the person on this computer, each with the button that does
  /// it where one can: the status bar's list.
  List<_Item> get _attention {
    final items = <_Item>[];
    if (app.agents case final agents?) {
      if (agents.isEmpty) {
        items.add((
          tab: _Tab.agents,
          short: 'No coding agent found',
          text: 'No coding agent found: install omp or Claude Code, and PocketTerm offers to set it up here',
          action: null,
        ));
      }
      for (final MapEntry(key: agent, value: check) in agents.entries) {
        final name = Integrations.name(agent);
        final failed = _installNotes[agent]?.color == _error ? _installNotes[agent]!.text : null;
        switch (integrationOf(check)) {
          case AgentIntegration.installed:
            break;
          case AgentIntegration.off:
            items.add((tab: _Tab.agents, short: '$name has mods off', text: Integrations.modsOffHint, action: null));
          case AgentIntegration.outdated:
            items.add((
              tab: _Tab.agents,
              short: 'PocketTerm in $name is out of date',
              text: failed ?? 'PocketTerm in $name is out of date',
              action: _agentButton(agent, 'Update'),
            ));
          case AgentIntegration.missing:
            final problem = check.state.problem;
            items.add((
              tab: _Tab.agents,
              short: problem ?? 'PocketTerm isn’t installed in $name',
              text: problem ?? failed ?? 'PocketTerm isn’t installed in $name',
              action: problem == null ? _agentButton(agent, 'Install') : null,
            ));
        }
      }
    }
    for (final agent in Agent.values) {
      final n = _unreported.where((w) => w.agent == agent).length;
      if (n == 0) continue;
      items.add((
        tab: _Tab.agents,
        short: switch (agent) {
          Agent.claude => '${_count(n, 'Claude Code session')} to reload',
          Agent.omp => '${_count(n, 'omp session')} to reopen',
        },
        text: switch (agent) {
          Agent.claude =>
            '${_count(n, 'Claude Code session')} opened before PocketTerm: type ${agent.pickUp} in '
                '${n == 1 ? 'it' : 'them'}',
          Agent.omp =>
            '${_count(n, 'omp session')} opened before PocketTerm: quit omp in '
                '${n == 1 ? 'it' : 'them'} and run ${agent.resume}',
        },
        action: null,
      ));
    }
    final terminals = _terminals ?? const <TermStatus>[];
    for (final s in terminalsNeedingSetup(terminals)) {
      items.add((
        tab: _Tab.terminals,
        short: '${s.label} needs setup',
        // Their notes name the terminal already.
        text: _fixed[s.id]?.note ?? (s.note.isEmpty ? '${s.label} needs setup' : s.note),
        action: _fixButton(s),
      ));
    }
    if (_terminals != null && noTerminalApp(terminals)) {
      items.add((
        tab: _Tab.terminals,
        short: 'No terminal app found',
        text: 'No terminal app found: PocketTerm works with kitty, Ghostty and WezTerm',
        action: null,
      ));
    }
    if (_clock case final clock?) {
      items.add((tab: _Tab.account, short: 'This computer’s clock is off', text: clock, action: null));
    }
    if (app.phoneClockOff case final off?) {
      final minutes = (off.inSeconds.abs() / 60).round();
      items.add((
        tab: _Tab.phone,
        short: 'A phone’s clock is off',
        text:
            'A phone’s clock is $minutes minutes ${off.isNegative ? 'behind' : 'ahead of'} this computer’s, so '
            'what it sends is refused: turn on automatic date and time on both',
        action: null,
      ));
    }
    if (app.hosting case final h? when h.state != HostState.ready && h.state != HostState.checking) {
      final open = h.state == HostState.tailscaleOff || h.state == HostState.loggedOut;
      items.add((
        tab: _Tab.account,
        short: 'Phones can’t reach your server',
        text: switch (h.state) {
          HostState.noTailscale => 'Tailscale isn’t installed, so phones can’t reach the server on this computer',
          HostState.tailscaleOff => 'Tailscale isn’t running, so phones can’t reach the server on this computer',
          HostState.loggedOut => 'Tailscale is signed out, so phones can’t reach the server on this computer',
          _ => 'Tailscale doesn’t serve this computer’s server, so phones can’t reach it: see Account',
        },
        action: open
            ? _button(
                'Open Tailscale',
                () => unawaited(h.tailscale.open()),
                key: const ValueKey('attention-open-tailscale'),
              )
            : null,
      ));
    } else if (app.hosting?.renamedFrom case final old?) {
      items.add((
        tab: _Tab.account,
        short: 'Tailscale address changed',
        text: 'This computer’s Tailscale address changed from ${old.host}: each phone must scan its code again',
        action: _button('Add a phone…', () {
          app.hosting?.renameSeen();
          unawaited(showPairingQr(context, app));
        }),
      ));
    }
    if (app.phoneSignedIn == false) {
      items.add((
        tab: _Tab.phone,
        short: 'No phone yet',
        text: 'No phone signed in yet',
        action: _button('Add a phone…', () => unawaited(showPairingQr(context, app))),
      ));
    }
    if (app.projectRoots.isEmpty) {
      items.add((
        tab: _Tab.phone,
        short: 'No project folders',
        text: 'No project folders: your phone can’t list your projects',
        action: _button('Add folder…', () => unawaited(_addFolders())),
      ));
    }
    return items;
  }

  /// Settings' top: all set, or what needs attention (listed on Show); and the way back to the setup
  /// checklist.
  Widget _statusBar({required bool checking, required List<_Item> items}) {
    final n = items.length;
    final ok = !checking && n == 0;
    return Container(
      key: const ValueKey('settings-status'),
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      decoration: BoxDecoration(
        color: n > 0 ? C.warn.withValues(alpha: .07) : C.field,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: n > 0 ? C.warn.withValues(alpha: .5) : C.line2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                // Not a spinner: a look may take a while (claude), and nothing moves meanwhile.
                checking ? Icons.more_horiz : (ok ? Icons.check_circle : Icons.warning_amber_rounded),
                size: 18,
                color: checking ? C.dim : (ok ? C.ok : C.warn),
              ),
              const SizedBox(width: 10),
              Text(
                checking
                    ? 'Checking this computer…'
                    : ok
                    ? 'All set'
                    : '$n ${n == 1 ? 'thing needs' : 'things need'} attention',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: checking
                      ? C.text
                      : ok
                      ? C.ok
                      : C.warn,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  [for (final i in items) i.short].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: C.dim),
                ),
              ),
              if (n > 0)
                _link(_showAttention ? 'Hide' : 'Show', () => setState(() => _showAttention = !_showAttention)),
              _link('Open setup checklist', () => unawaited(app.setGetReadyDone(done: false))),
            ],
          ),
          if (_showAttention && n > 0)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final item in items)
                      Padding(
                        padding: const EdgeInsets.only(left: 28, top: 6, right: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(item.text, style: const TextStyle(fontSize: 12, color: C.warn, height: 1.35)),
                            ),
                            if (item.action case final a?) ...[const SizedBox(width: 10), a],
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// A newer PocketTerm, under the status bar.
  Widget _updateBar(UpdateInfo u) => Container(
    key: const ValueKey('settings-update'),
    padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
    decoration: BoxDecoration(
      color: C.field,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: C.accent.withValues(alpha: .5)),
    ),
    child: Row(
      children: [
        const Icon(Icons.system_update_alt, size: 18, color: C.accent),
        const SizedBox(width: 10),
        Expanded(child: Text('PocketTerm ${u.version} is out', style: const TextStyle(fontSize: 13))),
        _button('Download', () => unawaited(launchUrl(u.url, mode: LaunchMode.externalApplication)), primary: true),
      ],
    ),
  );

  // ---------------------------------------------------------------- pieces

  static const _error = Color(0xFFFCA5A5);

  static TextStyle _subStyle(Color color) => TextStyle(fontSize: 12, color: color, height: 1.45);

  /// A card: [title] and [sub] beside [leading] and [trailing], [body] below.
  Widget _card({
    Key? key,
    String? title,
    String? sub,
    Color subColor = C.dim,
    Widget? leading,
    Widget? trailing,
    List<Widget> body = const [],
  }) => Container(
    key: key,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: C.field,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: C.line2),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [
        Row(
          children: [
            if (leading != null) ...[leading, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 3,
                children: [
                  if (title != null) Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  if (sub != null) Text(sub, style: _subStyle(subColor)),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 10), trailing],
          ],
        ),
        ...body,
      ],
    ),
  );

  Widget _link(String label, VoidCallback onPressed) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      foregroundColor: C.accent,
      padding: const EdgeInsets.symmetric(horizontal: 8),
    ),
    child: Text(label, style: const TextStyle(fontSize: 12)),
  );

  Widget _chip(
    String label, {
    required VoidCallback onTap,
    Key? key,
    IconData? leading,
    IconData? trailing,
    String? tooltip,
  }) {
    final chip = Hoverable(
      key: key,
      onTap: onTap,
      builder: (h) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: h ? const Color(0xFF2E313D) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.line2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 5,
          children: [
            if (leading != null) Icon(leading, size: 14, color: C.dim),
            Text(label, style: const TextStyle(fontSize: 12)),
            if (trailing != null) Icon(trailing, size: 13, color: C.dim),
          ],
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }

  Widget _button(
    String label,
    VoidCallback onTap, {
    Key? key,
    bool danger = false,
    bool active = false,
    bool primary = false,
  }) => Hoverable(
    key: key,
    onTap: onTap,
    builder: (h) => Container(
      constraints: const BoxConstraints(minWidth: 70),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: primary
            ? (h ? const Color(0xFF93AEFF) : C.accent)
            : h
            ? const Color(0xFF2E313D)
            : const Color(0xFF262833),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: primary ? C.accent : (active ? C.accent : C.line2)),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          fontWeight: primary ? FontWeight.w600 : null,
          color: primary ? const Color(0xFF12141C) : (danger ? _error : (active ? C.accent : C.text)),
        ),
      ),
    ),
  );
}
