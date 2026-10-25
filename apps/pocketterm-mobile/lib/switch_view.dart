import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';
import 'package:pocketterm_mobile/coach.dart';
import 'package:pocketterm_mobile/motion.dart';
import 'package:pocketterm_mobile/session_view.dart';
import 'package:pocketterm_mobile/terminal_view.dart';

/// Whether [w] is a coding agent's window that shows only as a screen and the phone can switch it to the
/// conversation view: no live session claims it, PocketTerm is installed in its agent on the computer (so a
/// restarted or reloaded agent reports), and its terminal presses keys and types.
bool canSwitch(TerminalRemote remote, TermWindow w) {
  final agent = w.agent;
  return agent != null &&
      remote.agents[agent] == AgentIntegration.installed &&
      w.can(TermCap.keys) &&
      w.can(TermCap.type) &&
      !remote.sessions.any((s) => s.window == w.key);
}

/// How long the phone waits for the switched agent to report as a session.
const switchWait = Duration(seconds: 25);

enum _Phase { idle, switching, failed }

/// What the session page does once a switched agent reports: an omp that was at work when its restart stopped it
/// is prompted `continue` right away ([send]), or offers a Continue chip ([offer]).
enum AfterSwitch { nothing, offer, send }

/// The top of a screen-only agent window's page ([canSwitch]): a banner offering the switch to the conversation
/// view, then "Switching…" until the agent reports as a live session in this window, whose page then replaces this
/// one; or, after [switchWait], that it didn't come back.
class SwitchBanner extends StatefulWidget {
  const SwitchBanner({required this.remote, required this.window, super.key});
  final TerminalRemote remote;
  final String window;

  @override
  State<SwitchBanner> createState() => _SwitchBannerState();
}

class _SwitchBannerState extends State<SwitchBanner> {
  TerminalRemote get remote => widget.remote;
  _Phase _phase = _Phase.idle;

  /// The agent being switched: its window's program is a shell for a moment while omp restarts.
  late Agent _agent;

  /// What its session page does about a run the switch stopped.
  AfterSwitch _after = AfterSwitch.nothing;
  Timer? _timeout;

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _stop() {
    _timeout?.cancel();
    _timeout = null;
    remote.removeListener(_check);
  }

  Future<void> _offer(Agent agent) async {
    final after = await showAppSheet<AfterSwitch>(
      context,
      // Its height is its content's: the choices at work take more than the default share of the screen.
      isScrollControlled: true,
      builder: (_) => SwitchSheet(remote: remote, window: widget.window, agent: agent),
    );
    if (after == null || !mounted) return;
    setState(() {
      _phase = _Phase.switching;
      _agent = agent;
      _after = after;
    });
    _stop();
    remote.addListener(_check);
    _timeout = Timer(switchWait, () {
      _stop();
      if (mounted) setState(() => _phase = _Phase.failed);
    });
    try {
      await remote.switchToConversation(widget.window, agent);
    } on Object catch (e) {
      if (!mounted || _phase != _Phase.switching) return;
      _stop();
      setState(() => _phase = _Phase.idle);
      termToast(context, e);
    }
  }

  /// The agent reported from this window: its session's page takes this one's place.
  void _check() {
    final s = remote.sessions.where((s) => s.window == widget.window).firstOrNull;
    if (s == null || !mounted || _phase != _Phase.switching) return;
    _stop();
    Coach.maybeOf(context)?.switched(widget.window);
    final route = ModalRoute.of(context);
    final page = MaterialPageRoute<void>(
      builder: (_) => SessionPage(
        remote: remote,
        sessionKey: s.key,
        offerContinue: _after == AfterSwitch.offer,
        autoContinue: _after == AfterSwitch.send,
      ),
    );
    final nav = Navigator.of(context);
    if (route == null || route.isCurrent) {
      nav.pushReplacement(page);
    } else {
      nav.replace(oldRoute: route, newRoute: page);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = remote.window(widget.window);
    final online = remote.online;
    final banner = switch (_phase) {
      _Phase.idle when w != null && canSwitch(remote, w) => _bar(
        const ValueKey('switch-offer'),
        'This ${w.agent!.label} session shows only its screen',
        CoachTarget(
          tip: Tip.switchButton,
          radius: 20,
          padding: 0,
          child: TextButton(
            key: const ValueKey('switch-open'),
            onPressed: online ? () => unawaited(_offer(w.agent!)) : null,
            child: const Text('Switch to conversation'),
          ),
        ),
      ),
      _Phase.idle => null,
      _Phase.switching => _bar(
        const ValueKey('switching'),
        'Switching…',
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      ),
      _Phase.failed => _bar(
        const ValueKey('switch-failed'),
        'It didn’t come back as a conversation.',
        TextButton(
          key: const ValueKey('switch-retry'),
          onPressed: online ? () => unawaited(_offer(_agent)) : null,
          child: const Text('Try again'),
        ),
      ),
    };
    return Reveal(visible: banner != null, child: banner ?? const SizedBox.shrink());
  }

  Widget _bar(Key key, String text, Widget action) => Container(
    key: key,
    color: C.bar,
    padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
    // Narrow (a split screen, large text): the action takes at most about half and wraps, the text the rest.
    child: LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 14, color: C.dim)),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxWidth * .55),
            child: action,
          ),
        ],
      ),
    ),
  );
}

/// What switching [agent] in [window] does, asked before it's done. omp restarts, so the sheet first asks the
/// computer whether it's at work, warns that restarting stops it and offers to have it carry on. Pops what the
/// session page does about the stopped run once confirmed, null if not.
class SwitchSheet extends StatefulWidget {
  const SwitchSheet({required this.remote, required this.window, required this.agent, super.key});
  final TerminalRemote remote;
  final String window;
  final Agent agent;

  @override
  State<SwitchSheet> createState() => _SwitchSheetState();
}

class _SwitchSheetState extends State<SwitchSheet> {
  /// omp: whether it's at work; null while the computer is asked. Claude Code isn't asked: nothing restarts.
  bool? _busy;

  @override
  void initState() {
    super.initState();
    if (widget.agent == Agent.omp) {
      unawaited(_probe());
    } else {
      _busy = false;
    }
  }

  Future<void> _probe() async {
    var busy = false;
    try {
      busy = await widget.remote.probe(widget.window);
    } on Object {
      // Unknown: offered without the warning.
    }
    if (mounted) setState(() => _busy = busy);
  }

  @override
  Widget build(BuildContext context) {
    final omp = widget.agent == Agent.omp;
    final busy = _busy;
    return SafeArea(
      // Landscape or large text: the sheet scrolls rather than running off the screen.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, sheetTop, 20, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Switch to conversation', style: sheetTitleStyle),
            const SizedBox(height: 8),
            Text(
              omp
                  ? 'PocketTerm restarts omp in this window and picks the same conversation back up '
                        '(${Agent.omp.resume}). Nothing is lost.'
                  : 'PocketTerm types ${Agent.claude.pickUp} in it. Nothing restarts.',
              style: TextStyle(fontSize: 14, color: C.dim, height: 1.4),
            ),
            if (busy ?? false)
              Padding(
                key: const ValueKey('switch-busy'),
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 18, color: C.warn),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'It’s working right now, and restarting stops it. Restart and continue has it carry on; '
                        'Just restart leaves it stopped.',
                        style: TextStyle(fontSize: 14, color: C.warn, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            if (busy == null)
              const SizedBox(
                key: ValueKey('switch-probing'),
                height: 48,
                child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else if (busy)
              ..._busyChoices()
            else
              Wrap(
                alignment: WrapAlignment.end,
                runSpacing: 4,
                children: [
                  _notNow(),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('switch-confirm'),
                    onPressed: () => _pick(AfterSwitch.nothing),
                    child: Text(omp ? 'Restart now' : 'Switch'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  void _pick(AfterSwitch after) {
    unawaited(HapticFeedback.lightImpact());
    Navigator.of(context).pop(after);
  }

  Widget _notNow() => TextButton(
    key: const ValueKey('switch-cancel'),
    onPressed: () => Navigator.of(context).pop(),
    child: Text('Not now', style: TextStyle(color: C.text)),
  );

  /// omp at work: restart and have it carry on, or just restart, stacked so both read in full.
  List<Widget> _busyChoices() => [
    FilledButton(
      key: const ValueKey('switch-continue'),
      onPressed: () => _pick(AfterSwitch.send),
      child: const Text('Restart and continue'),
    ),
    const SizedBox(height: 8),
    OutlinedButton(
      key: const ValueKey('switch-confirm'),
      onPressed: () => _pick(AfterSwitch.offer),
      child: const Text('Just restart'),
    ),
    const SizedBox(height: 4),
    _notNow(),
  ];
}
