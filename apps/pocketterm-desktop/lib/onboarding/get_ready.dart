import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/controller.dart';
import 'package:pocketterm_desktop/hosting/built_in_server.dart';
import 'package:pocketterm_desktop/hosting/hosting_view.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_desktop/onboarding/confirm_install.dart';
import 'package:pocketterm_desktop/onboarding/pair.dart';
import 'package:pocketterm_desktop/onboarding/terminals_card.dart';
import 'package:pocketterm_desktop/terminal_fixes.dart';
import 'package:pocketterm_desktop/wezterm_setup.dart';

/// The setup checklist: what this computer and the phone need after the
/// first sign-in here, each step checking itself off as it gets done. The
/// signed-in window until it's finished ([AppController.getReadyDone]);
/// Settings' status bar opens it again.
///
/// 1. Coding agents: each agent found (omp, Claude Code) with whether
///    PocketTerm is in it; Install puts it there once the person read why
///    and confirmed ([confirmAgentInstall]), never on its own. Agent
///    sessions opened before it are listed with what picks it up there,
///    until they report.
/// 2. Terminals: the Mac's, each with its fix; WezTerm on Windows.
/// 3. Project folders (optional): the usual ones found in the home folder.
/// 4. Your phone: the pairing QR, until a phone has signed in.
class GetReadyPage extends StatefulWidget {
  const GetReadyPage({
    required this.app,
    this.poll = const Duration(seconds: 3),
    this.lookHidden = const Duration(minutes: 10),
    super.key,
  });
  final AppController app;

  /// How often the terminals' windows and the phone are looked at.
  final Duration poll;

  /// How long looking goes on once the window is hidden; while it shows,
  /// it keeps looking.
  final Duration lookHidden;

  @override
  State<GetReadyPage> createState() => _GetReadyPageState();
}

/// Windows' usual project folders that exist here: Visual Studio's and
/// GitHub Desktop's below [home], and GitHub Desktop's below OneDrive's
/// folders ([env]'s OneDrive, OneDriveConsumer, OneDriveCommercial), where
/// OneDrive's backup moves Documents.
List<String> windowsProjectFolders(String home, Map<String, String> env, bool Function(String dir) exists) => {
  p.windows.join(home, 'source', 'repos'),
  p.windows.join(home, 'Documents', 'GitHub'),
  for (final key in ['OneDrive', 'OneDriveConsumer', 'OneDriveCommercial'])
    if (env[key] case final root? when root.isNotEmpty) p.windows.join(root, 'Documents', 'GitHub'),
}.where(exists).toList();

enum _Step { agents, terminals, folders, phone }

enum _Status { done, action, optional, working }

class _GetReadyPageState extends State<GetReadyPage> {
  AppController get app => widget.app;

  /// Agents PocketTerm is going into now, and why it didn't go into others.
  final _installing = <Agent>{};
  final _failed = <Agent, String>{};

  /// Agent windows no live session claims; null until looked at.
  List<TermWindow>? _unreported;

  /// Mac: the terminals as the card last found them.
  List<TermStatus>? _terminals;

  /// Windows: installing WezTerm; null elsewhere.
  late final WezTermSetup? _wezterm = WezTermSetup.forHost(app.terminals.wezterm);

  Timer? _timer;
  StreamSubscription<void>? _live;

  /// When looking stops, the window being hidden; null while it shows.
  DateTime? _lookUntil;

  @override
  void initState() {
    super.initState();
    unawaited(app.checkAgents());
    unawaited(_look());
    _timer = Timer.periodic(widget.poll, (_) => unawaited(_look()));
    _live = app.live.changes.listen((_) => unawaited(_lookAtWindows()));
    app.mainShown.addListener(_shown);
    app.mainHidden.addListener(_hidden);
    _wezterm?.addListener(_changed);
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_live?.cancel());
    app.mainShown.removeListener(_shown);
    app.mainHidden.removeListener(_hidden);
    _wezterm?.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _shown() {
    _lookUntil = null;
    unawaited(app.checkAgents());
    unawaited(_look());
  }

  void _hidden() {
    if (app.mainHidden.value) _lookUntil ??= DateTime.now().add(widget.lookHidden);
  }

  Future<void> _install(Agent agent) async {
    final check = app.agents?[agent];
    final update = check != null && integrationOf(check) == AgentIntegration.outdated;
    if (!await confirmAgentInstall(context, agent, app.integrations, home: app.terminals.home, update: update)) return;
    if (!mounted) return;
    setState(() {
      _installing.add(agent);
      _failed.remove(agent);
    });
    String? error;
    try {
      await app.installAgent(agent);
    } on Object catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() {
      _installing.remove(agent);
      if (error != null) _failed[agent] = error;
    });
    await _lookAtWindows();
  }

  Future<void> _look() async {
    if (_lookUntil case final until? when DateTime.now().isAfter(until)) return;
    await _lookAtWindows();
    if (!(app.phoneSignedIn ?? false)) await app.checkPhone();
  }

  Future<void> _lookAtWindows() async {
    try {
      final windows = await app.terminals.windows();
      if (mounted) setState(() => _unreported = app.unreportedAgentWindows(windows));
    } on TerminalException {
      // As before.
    }
  }

  // ---------------------------------------------------------------- state

  _Status get _agentsStatus {
    final agents = app.agents;
    if (agents == null || _installing.isNotEmpty) return _Status.working;
    final ready =
        agents.isNotEmpty &&
        agents.values.every((c) => integrationOf(c) == AgentIntegration.installed) &&
        (_unreported?.isEmpty ?? true);
    return ready ? _Status.done : _Status.action;
  }

  _Status get _terminalsStatus {
    if (_wezterm case final w?) return w.installed ? _Status.done : _Status.action;
    final t = _terminals;
    if (t == null) return _Status.working;
    return terminalsNeedingSetup(t).isEmpty && !noTerminalApp(t) ? _Status.done : _Status.action;
  }

  _Status get _foldersStatus => app.projectRoots.isEmpty ? _Status.optional : _Status.done;

  _Status get _phoneStatus => switch (app.phoneSignedIn) {
    true => _Status.done,
    _ => _Status.action,
  };

  /// The essential steps not done yet, by name, for the Done button.
  List<String> get _left => [
    if (_agentsStatus != _Status.done) 'your coding agents',
    if (_terminalsStatus != _Status.done) 'your terminals',
  ];

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final left = _left;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Get this computer ready', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                'A few things so your phone sees your coding sessions and terminals. Each one checks itself off '
                'when it\u2019s done.',
                style: TextStyle(color: C.dim, height: 1.45),
              ),
              const SizedBox(height: 18),
              _step(_Step.agents, 'Your coding agents', _agentsStatus, _agentsBody()),
              _step(_Step.terminals, 'Your terminals', _terminalsStatus, _terminalsBody()),
              _step(_Step.folders, 'Project folders', _foldersStatus, _foldersBody(), optional: true),
              _step(_Step.phone, 'Your phone', _phoneStatus, _phoneBody()),
              const SizedBox(height: 8),
              if (left.isNotEmpty) ...[
                Text(
                  'Still to do: ${left.join(' and ')}. Settings keeps track of what\u2019s left.',
                  key: const ValueKey('get-ready-left'),
                  style: TextStyle(fontSize: 12.5, color: C.dim, height: 1.4),
                ),
                const SizedBox(height: 10),
              ],
              FilledButton(
                onPressed: () => unawaited(app.setGetReadyDone(done: true)),
                child: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Done')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _step(_Step step, String title, _Status status, Widget body, {bool optional = false}) {
    return Container(
      key: ValueKey('get-ready-${step.name}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: C.field,
        borderRadius: C.round(10),
        border: Border.all(color: C.line2, width: C.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox.square(
                dimension: 18,
                child: switch (status) {
                  _Status.done => Icon(Icons.check_circle, size: 18, color: C.ok),
                  _Status.action => Icon(Icons.error_outline, size: 18, color: C.warn),
                  _Status.optional => Icon(Icons.circle_outlined, size: 18, color: C.dim2),
                  _Status.working => const Padding(
                    padding: EdgeInsets.all(1),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                },
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    children: [
                      if (optional && status != _Status.done)
                        TextSpan(
                          text: '  Optional',
                          style: TextStyle(fontWeight: FontWeight.normal, fontSize: 12, color: C.dim),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          body,
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- agents

  Widget _agentsBody() {
    final agents = app.agents;
    final unreported = _unreported ?? const <TermWindow>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (agents == null)
          _line(_Status.working, 'Looking for omp and Claude Code…')
        else if (agents.isEmpty && _installing.isEmpty)
          _line(
            _Status.action,
            'No coding agent found. PocketTerm works with omp and Claude Code: install one, then come back here.',
          )
        else
          for (final agent in Agent.values) _agentLine(agent, agents[agent]),
        if (unreported.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'Sessions that were already open',
            key: ValueKey('get-ready-open-sessions'),
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 6),
          Text(
            'PocketTerm talks to your phone through a small add-on inside omp and Claude Code. An agent loads '
            'add-ons when it starts, so sessions opened before PocketTerm don\u2019t have it yet: your phone sees '
            'only their screen, not the conversation. Do this once in each; new sessions don\u2019t need it.',
            style: _note,
          ),
          for (final agent in Agent.values)
            if (unreported.any((w) => w.agent == agent))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(switch (agent) {
                  Agent.claude => '${Integrations.name(agent)}: type ${agent.pickUp} in it. Nothing restarts.',
                  Agent.omp =>
                    '${Integrations.name(agent)}: quit it and run ${agent.pickUp}. You\u2019re back in the same '
                        'conversation.',
                }, style: _note),
              ),
          const SizedBox(height: 6),
          Text(
            'Afterwards your phone shows the conversation: answer questions and approvals there and get a '
            'notification when a run finishes.',
            style: _note,
          ),
          for (final w in unreported) _unreportedLine(w),
        ],
      ],
    );
  }

  Widget _agentLine(Agent agent, AgentCheck? check) {
    final name = Integrations.name(agent);
    if (_installing.contains(agent)) return _line(_Status.working, 'Installing PocketTerm in $name…');
    if (_failed[agent] case final error?) {
      return _line(
        _Status.action,
        "Couldn't install PocketTerm in $name: $error",
        error: true,
        trailing: _textButton('Retry', () => unawaited(_install(agent))),
      );
    }
    if (check == null) {
      return _line(_Status.optional, '$name not found: install it later and PocketTerm offers it in Settings');
    }
    if (check.state.problem case final problem?) return _line(_Status.action, problem);
    return switch (integrationOf(check)) {
      AgentIntegration.installed => _line(_Status.done, 'PocketTerm is installed in $name'),
      AgentIntegration.off => _line(_Status.action, Integrations.modsOffHint),
      AgentIntegration.outdated => _line(
        _Status.action,
        'PocketTerm in $name is out of date',
        trailing: _textButton('Update', () => unawaited(_install(agent))),
      ),
      AgentIntegration.missing => _line(
        _Status.action,
        'PocketTerm isn\u2019t installed in $name',
        trailing: _textButton('Install', () => unawaited(_install(agent))),
      ),
    };
  }

  static TextStyle get _note => TextStyle(fontSize: 12.5, color: C.dim, height: 1.4);

  Widget _unreportedLine(TermWindow w) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: SessionToPickUp(window: w, terminals: app.terminals, key: ValueKey('get-ready-unreported-${w.key}')),
  );

  // ---------------------------------------------------------------- terminals

  Widget _terminalsBody() {
    if (_wezterm case final w?) return WezTermCard(setup: w);
    return MacTerminalsCard(
      terminals: app.terminals,
      commands: app.commands,
      onStatuses: (s) {
        if (mounted) setState(() => _terminals = s);
      },
    );
  }

  // ---------------------------------------------------------------- folders

  /// Where projects usually live, below the home folder.
  static const _usual = ['Dev', 'Developer', 'Projects', 'projects', 'code', 'Code', 'src', 'repos', 'dev', 'git'];

  /// The usual project folders that exist here and aren't added yet. The
  /// home folder is listed rather than each name tried, so a Mac's
  /// case-insensitive disk doesn't offer ~/Projects twice.
  List<String> _suggestions() {
    final home = app.terminals.home;
    final roots = app.projectRoots.toSet();
    final found = <String>[];
    try {
      for (final e in Directory(home).listSync(followLinks: false)) {
        if (e is Directory && _usual.contains(p.basename(e.path))) found.add(e.path);
      }
    } on FileSystemException {
      // No home folder to look in.
    }
    if (Platform.isWindows) {
      found.addAll(windowsProjectFolders(home, Platform.environment, (d) => Directory(d).existsSync()));
    }
    found.sort();
    return [
      for (final f in found)
        if (!roots.contains(f)) f,
    ];
  }

  Future<void> _addFolders(List<String> picked) async {
    if (picked.isEmpty) return;
    await app.setProjectRoots({...app.projectRoots, ...picked}.toList());
  }

  Widget _foldersBody() {
    final roots = app.projectRoots;
    final suggested = _suggestions();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Your phone lists the git repositories in these and starts new projects there.',
          style: TextStyle(color: C.dim, height: 1.45, fontSize: 13),
        ),
        for (final r in roots) Padding(padding: const EdgeInsets.only(top: 8), child: _line(_Status.done, _tilde(r))),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in suggested)
              OutlinedButton.icon(
                key: ValueKey('get-ready-folder-$s'),
                onPressed: () => unawaited(_addFolders([s])),
                icon: const Icon(Icons.add, size: 16),
                label: Text(_tilde(s), style: const TextStyle(fontSize: 12.5)),
                style: _chipStyle,
              ),
            OutlinedButton(
              onPressed: () => unawaited(app.host.pickFolders().then(_addFolders)),
              style: _chipStyle,
              child: const Text('Choose folder…', style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
      ],
    );
  }

  static ButtonStyle get _chipStyle => OutlinedButton.styleFrom(
    foregroundColor: C.text,
    side: BorderSide(color: C.line2, width: C.border),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    visualDensity: VisualDensity.compact,
  );

  // ---------------------------------------------------------------- phone

  Widget _phoneBody() {
    if (app.phoneSignedIn ?? false) {
      return Text(
        'A phone is signed in. To add another: Settings \u2192 Phone \u2192 Add a phone\u2026',
        style: TextStyle(color: C.dim, height: 1.45, fontSize: 13),
      );
    }
    // A computer running the server: the phone's code needs Tailscale's address.
    if (app.hosting case final h? when h.state != HostState.ready) return HostingStatusView(server: h);
    // Through Tailscale (this computer's server, or another computer's): the phone needs it too.
    final tailscale = app.hosting != null || (app.backend?.host.endsWith('.ts.net') ?? false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tailscale) ...[
          Text(
            phoneTailscaleNote,
            key: const ValueKey('get-ready-phone-tailscale'),
            style: TextStyle(color: C.dim, height: 1.45, fontSize: 13),
          ),
          const SizedBox(height: 12),
        ],
        PairingQr(session: app),
        const SizedBox(height: 10),
        Text(
          'PocketTerm for iPhone is on TestFlight and for Android on Google Play internal testing, '
          'for invited testers.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, color: C.dim2, height: 1.4),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- pieces

  String _tilde(String path) => _tildePath(path, app.terminals.home);

  Widget _line(_Status status, String text, {Widget? trailing, bool error = false}) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      children: [
        SizedBox.square(
          dimension: 16,
          child: switch (status) {
            _Status.done => Icon(Icons.check, size: 16, color: C.ok),
            _Status.action => Icon(
              error ? Icons.error_outline : Icons.warning_amber_rounded,
              size: 16,
              color: error ? C.error : C.warn,
            ),
            _Status.optional => Icon(Icons.remove, size: 16, color: C.dim2),
            _Status.working => const Padding(
              padding: EdgeInsets.all(2),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          },
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: error ? C.error : (status == _Status.optional ? C.dim : C.text),
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );

  Widget _textButton(String label, VoidCallback onPressed, {Key? key}) => TextButton(
    key: key,
    onPressed: onPressed,
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
    ),
    child: Text(label),
  );
}

/// An agent session opened before PocketTerm was in its agent: where it runs, and what to type there to pick
/// PocketTerm up ([Agent.pickUp]) with a button that copies it. The setup checklist and Settings list these.
class SessionToPickUp extends StatefulWidget {
  const SessionToPickUp({required this.window, required this.terminals, super.key});
  final TermWindow window;
  final Terminals terminals;

  @override
  State<SessionToPickUp> createState() => _SessionToPickUpState();
}

class _SessionToPickUpState extends State<SessionToPickUp> {
  /// The command was copied: the button says so (the window has no snackbar).
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final w = widget.window;
    final agent = w.agent!;
    final cwd = _tildePath(w.cwd, widget.terminals.home);
    final where = [
      if (w.cwd.isNotEmpty) 'in $cwd',
      widget.terminals.hosts.where((h) => h.id == w.app).firstOrNull?.label ?? w.app,
    ].join(' · ');
    // As typed: the no-break characters keep it whole on screen, not in a terminal.
    final typed = agent.pickUp.replaceAll('\u00A0', ' ').replaceAll('\u2060', '');
    return Row(
      children: [
        Icon(Icons.refresh, size: 18, color: C.warn),
        const SizedBox(width: 10),
        Expanded(child: Text('${Integrations.name(agent)} $where', style: const TextStyle(fontSize: 13))),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.only(left: 8),
          decoration: BoxDecoration(
            color: C.win,
            borderRadius: C.round(6),
            border: Border.all(color: C.line2, width: C.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(agent.pickUp, style: monoStyle),
              IconButton(
                tooltip: _copied ? 'Copied' : 'Copy',
                iconSize: 14,
                visualDensity: VisualDensity.compact,
                color: _copied ? C.ok : C.dim,
                icon: Icon(_copied ? Icons.check : Icons.copy_outlined),
                onPressed: () {
                  unawaited(Clipboard.setData(ClipboardData(text: typed)));
                  setState(() => _copied = true);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// [path] with [home] as `~`.
String _tildePath(String path, String home) {
  if (path == home) return '~';
  return p.isWithin(home, path) ? '~${path.substring(home.length)}' : path;
}

/// A command as typed in a terminal.
const monoStyle = TextStyle(fontSize: 12, fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace']);
