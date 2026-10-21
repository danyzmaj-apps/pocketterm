import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/controller.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_desktop/onboarding/pair.dart';
import 'package:pocketterm_desktop/onboarding/terminals_card.dart';
import 'package:pocketterm_desktop/terminal_fixes.dart';
import 'package:pocketterm_desktop/wezterm_setup.dart';

/// The setup checklist: what this computer and the phone need after the
/// first sign-in here, each step checking itself off as it gets done. The
/// signed-in window until it's finished or skipped ([AppController.getReadyDone]);
/// Settings' status card opens it again.
///
/// 1. Coding agents: PocketTerm goes into every agent found (omp, Claude
///    Code) as soon as this shows; agent sessions that started before it
///    are listed until they're restarted.
/// 2. Terminals: the Mac's, each with its fix; WezTerm on Windows.
/// 3. Project folders (optional): the usual ones found in the home folder.
/// 4. Your phone: the pairing QR, until a phone has signed in.
class GetReadyPage extends StatefulWidget {
  const GetReadyPage({required this.app, this.poll = const Duration(seconds: 3), super.key});
  final AppController app;

  /// How often the terminals' windows and the phone are looked at.
  final Duration poll;

  @override
  State<GetReadyPage> createState() => _GetReadyPageState();
}

enum _Step { agents, terminals, folders, phone }

enum _Status { done, action, optional, working }

class _GetReadyPageState extends State<GetReadyPage> {
  AppController get app => widget.app;

  final _skipped = <_Step>{};

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

  /// Looking stops this long after the window was last shown, should it
  /// sit hidden.
  static const _lookFor = Duration(minutes: 10);
  late DateTime _lookUntil = DateTime.now().add(_lookFor);

  @override
  void initState() {
    super.initState();
    unawaited(_setUpAgents());
    unawaited(_look());
    _timer = Timer.periodic(widget.poll, (_) => unawaited(_look()));
    _live = app.live.changes.listen((_) => unawaited(_lookAtWindows()));
    app.mainShown.addListener(_shown);
    _wezterm?.addListener(_changed);
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_live?.cancel());
    app.mainShown.removeListener(_shown);
    _wezterm?.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _shown() {
    _lookUntil = DateTime.now().add(_lookFor);
    unawaited(app.checkAgents());
    unawaited(_look());
  }

  /// PocketTerm into every agent found that lacks it or has an old copy.
  Future<void> _setUpAgents() async {
    await app.checkAgents();
    for (final MapEntry(key: agent, value: check) in {...?app.agents}.entries) {
      if (!mounted) return;
      final s = check.state;
      if (s.problem == null && !(s.installed && s.current)) await _install(agent);
    }
  }

  Future<void> _install(Agent agent) async {
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
    if (DateTime.now().isAfter(_lookUntil)) return;
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
              const Text(
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
                  style: const TextStyle(fontSize: 12.5, color: C.dim, height: 1.4),
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
    final skipped = _skipped.contains(step) && status != _Status.done;
    return Container(
      key: ValueKey('get-ready-${step.name}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: C.field,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: C.line2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox.square(
                dimension: 18,
                child: skipped
                    ? const Icon(Icons.remove_circle_outline, size: 18, color: C.dim2)
                    : switch (status) {
                        _Status.done => const Icon(Icons.check_circle, size: 18, color: C.ok),
                        _Status.action => const Icon(Icons.error_outline, size: 18, color: C.warn),
                        _Status.optional => const Icon(Icons.circle_outlined, size: 18, color: C.dim2),
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
                      if (skipped)
                        const TextSpan(
                          text: '  Skipped',
                          style: TextStyle(fontWeight: FontWeight.normal, fontSize: 12, color: C.dim),
                        )
                      else if (optional && status != _Status.done)
                        const TextSpan(
                          text: '  Optional',
                          style: TextStyle(fontWeight: FontWeight.normal, fontSize: 12, color: C.dim),
                        ),
                    ],
                  ),
                ),
              ),
              if (status != _Status.done)
                _textButton(
                  skipped ? 'Show' : 'Skip',
                  () => setState(() => skipped ? _skipped.remove(step) : _skipped.add(step)),
                  key: ValueKey('get-ready-skip-${step.name}'),
                ),
            ],
          ),
          if (!skipped) ...[const SizedBox(height: 10), body],
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
          const SizedBox(height: 14),
          const Text(
            'Started before PocketTerm was in them, so your phone sees only their screens:',
            style: TextStyle(fontSize: 12.5, color: C.dim, height: 1.4),
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

  Widget _unreportedLine(TermWindow w) {
    final agent = w.agent!;
    final where = [
      if (w.cwd.isNotEmpty) _tilde(w.cwd),
      app.terminals.hosts.where((h) => h.id == w.app).firstOrNull?.label ?? w.app,
    ].join(' · ');
    return Padding(
      key: ValueKey('get-ready-unreported-${w.key}'),
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.restart_alt, size: 18, color: C.warn),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${agent.label} in $where', style: const TextStyle(fontSize: 13)),
                Text.rich(
                  TextSpan(
                    text: 'Restart it: quit ${agent.label} there and run ',
                    children: [
                      TextSpan(
                        text: '${agent.command} -c',
                        style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace']),
                      ),
                    ],
                  ),
                  style: const TextStyle(fontSize: 11.5, color: C.dim, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- terminals

  Widget _terminalsBody() {
    if (_wezterm case final w?) return WezTermCard(setup: w);
    return MacTerminalsCard(
      terminals: app.terminals,
      onStatuses: (s) {
        if (mounted) setState(() => _terminals = s);
      },
    );
  }

  // ---------------------------------------------------------------- folders

  /// Where projects usually live, below the home folder.
  static const _usual = ['Dev', 'Developer', 'Projects', 'projects', 'code', 'Code', 'src', 'repos', 'dev', 'git'];

  /// Windows: Visual Studio's and GitHub Desktop's own places.
  static const _usualWindows = ['source/repos', 'Documents/GitHub'];

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
      for (final rel in _usualWindows) {
        final dir = p.joinAll([home, ...rel.split('/')]);
        if (Directory(dir).existsSync()) found.add(dir);
      }
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
        const Text(
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

  static final ButtonStyle _chipStyle = OutlinedButton.styleFrom(
    foregroundColor: C.text,
    side: const BorderSide(color: C.line2),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    visualDensity: VisualDensity.compact,
  );

  // ---------------------------------------------------------------- phone

  Widget _phoneBody() {
    if (app.phoneSignedIn ?? false) {
      return const Text(
        'A phone is signed in. To add another: Settings \u2192 Set up phone.',
        style: TextStyle(color: C.dim, height: 1.45, fontSize: 13),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PairingQr(session: app),
        const SizedBox(height: 10),
        const Text(
          'PocketTerm for iPhone is on TestFlight and for Android on Google Play internal testing, '
          'for invited testers.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, color: C.dim2, height: 1.4),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- pieces

  /// [path] with the home folder as `~`.
  String _tilde(String path) {
    final home = app.terminals.home;
    if (path == home) return '~';
    return p.isWithin(home, path) ? '~${path.substring(home.length)}' : path;
  }

  Widget _line(_Status status, String text, {Widget? trailing, bool error = false}) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      children: [
        SizedBox.square(
          dimension: 16,
          child: switch (status) {
            _Status.done => const Icon(Icons.check, size: 16, color: C.ok),
            _Status.action => Icon(
              error ? Icons.error_outline : Icons.warning_amber_rounded,
              size: 16,
              color: error ? const Color(0xFFFCA5A5) : C.warn,
            ),
            _Status.optional => const Icon(Icons.remove, size: 16, color: C.dim2),
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
              color: error ? const Color(0xFFFCA5A5) : (status == _Status.optional ? C.dim : C.text),
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
