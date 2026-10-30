import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/speech.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';
import 'package:pocketterm_mobile/drafts.dart';
import 'package:pocketterm_mobile/session_view.dart';
import 'package:pocketterm_mobile/terminal_view.dart';
import 'package:pocketterm_mobile/voice.dart';

// The computer's orchestrator (LiveSummary.orchestrator): an omp session the computer starts in PocketTerm's own
// folder, with tools to see and steer its other sessions. The Terminal list shows it as a bar beside the +, not as
// a project; the bar opens it as a chat.

const _ask = 'Ask about your sessions…';

/// The bar at the bottom of the Terminal list: what the orchestrator is up to; a tap opens it ([showOrchestrator]).
/// Shown once the computer's omp can run one (PocketTerm installed in it), or one runs.
class OrchestratorBar extends StatelessWidget {
  const OrchestratorBar({required this.remote, this.computer, super.key});
  final TerminalRemote remote;

  /// The computer's name, as the phone calls it.
  final String? computer;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: remote,
    builder: (context, _) {
      final o = remote.orchestrator;
      if (o == null && remote.agents[Agent.omp] != AgentIntegration.installed) return const SizedBox.shrink();
      final (text, color) = switch (o) {
        null => (_ask, C.dim),
        LiveSummary(:final ask?) => ('Needs you: ${ask.text}', C.warn),
        LiveSummary(busy: true) => ('Working…', C.accent),
        LiveSummary(:final preview) when preview.isNotEmpty => (preview, C.text),
        _ => (_ask, C.dim),
      };
      final working = o != null && o.ask == null && o.busy;
      return Semantics(
        identifier: 'orchestrator-bar',
        container: true,
        button: true,
        label: 'Orchestrator',
        child: Material(
          key: const ValueKey('orchestrator-bar'),
          color: isIos ? M.container : M.containerHigh,
          elevation: 2,
          borderRadius: BorderRadius.circular(C.r(28)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => unawaited(showOrchestrator(context, remote, computer: computer)),
            child: SizedBox(
              height: 56,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome, size: 20, color: C.accent),
                    const SizedBox(width: 12),
                    if (working) ...[
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: C.accent),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, color: color),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Opens the orchestrator's chat over everything: what was asked and answered, and a composer that starts the
/// orchestrator on the computer when none runs.
Future<void> showOrchestrator(BuildContext context, TerminalRemote remote, {String? computer}) {
  final error = ValueNotifier<String?>(null);
  // The session page answers what it asks, and shows its whole transcript; the list's context outlives the sheet.
  void open(BuildContext sheet, String key) {
    Navigator.of(sheet).pop();
    if (context.mounted) openSession(context, remote, key);
  }

  return showFullscreenModal<void>(
    context,
    title: ListenableBuilder(
      listenable: remote,
      builder: (context, _) {
        final o = remote.orchestrator;
        final state = switch (o) {
          LiveSummary(ask: _?) => ' · Needs you',
          LiveSummary(busy: true) => ' · Working…',
          _ => '',
        };
        return Text.rich(
          TextSpan(
            text: 'Orchestrator',
            children: [
              if (state.isNotEmpty)
                TextSpan(
                  text: state,
                  style: TextStyle(color: C.dim),
                ),
            ],
          ),
        );
      },
    ),
    actions: [
      ListenableBuilder(
        listenable: remote,
        builder: (sheet, _) {
          final o = remote.orchestrator;
          if (o == null || !o.busy || !remote.online) return const SizedBox.shrink();
          return IconButton(
            key: const ValueKey('orchestrator-stop'),
            tooltip: 'Stop',
            icon: Icon(Icons.stop_circle_outlined, color: C.dim),
            onPressed: () async {
              try {
                await remote.abort(o.key);
              } on TerminalException catch (e) {
                error.value = e.message;
              } on Object catch (e) {
                error.value = '$e';
              }
            },
          );
        },
      ),
      ListenableBuilder(
        listenable: remote,
        builder: (sheet, _) {
          final o = remote.orchestrator;
          if (o == null) return const SizedBox.shrink();
          return IconButton(
            key: const ValueKey('orchestrator-open'),
            tooltip: 'Open conversation',
            icon: Icon(Icons.open_in_full, color: C.dim),
            onPressed: () => open(sheet, o.key),
          );
        },
      ),
    ],
    closeKey: const ValueKey('orchestrator-close'),
    builder: (sheet) =>
        OrchestratorSheet(remote: remote, computer: computer, error: error, onOpen: (key) => open(sheet, key)),
  ).whenComplete(error.dispose);
}

/// The orchestrator's chat: the person's prompts and its answers (no tools), and a composer whose microphone
/// listens only while held and puts what it heard into the field.
class OrchestratorSheet extends StatefulWidget {
  const OrchestratorSheet({
    required this.remote,
    required this.error,
    required this.onOpen,
    this.computer,
    super.key = const ValueKey('orchestrator-sheet'),
  });

  final TerminalRemote remote;
  final String? computer;

  /// What went wrong last, shown above the composer; the sheet's Stop sets it too.
  final ValueNotifier<String?> error;

  /// Opens session [key]'s own page.
  final void Function(String key) onOpen;

  @override
  State<OrchestratorSheet> createState() => _OrchestratorSheetState();
}

enum _Voice { off, checking, listening, stopping }

class _OrchestratorSheetState extends State<OrchestratorSheet> {
  TerminalRemote get remote => widget.remote;
  final _field = TextEditingController();
  final _focus = FocusNode();
  late final String _draftKey = routedKey(remote.desktopId, 'orchestrator');

  /// The orchestrator the computer streams to this phone: without a watch it sends no transcript.
  VoidCallback? _unwatch;
  String? _watched;

  bool _sending = false;
  bool _starting = false;

  _Voice _voice = _Voice.off;

  /// What was heard so far while held, and how loud.
  String _live = '';
  double _level = 0;

  /// The finger came up (perhaps before listening started).
  bool _released = false;
  StreamSubscription<SpeechEvent>? _sub;
  Timer? _stopWait;

  @override
  void initState() {
    super.initState();
    remote.addListener(_follow);
    _follow();
    unawaited(
      loadDraft(_draftKey).then((text) {
        // Typed before it came: what's in the field wins.
        if (!mounted || text.isEmpty || _field.text.isNotEmpty) return;
        _field.text = text;
      }),
    );
  }

  @override
  void dispose() {
    unawaited(saveDraft(_draftKey, _field.text));
    remote.removeListener(_follow);
    _unwatch?.call();
    // Discards what was heard.
    unawaited(_sub?.cancel());
    _stopWait?.cancel();
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Watches the orchestrator there is now, if it changed.
  void _follow() {
    final key = remote.orchestrator?.key;
    if (key == _watched) return;
    _unwatch?.call();
    _unwatch = key == null ? null : remote.watchSession(key);
    _watched = key;
  }

  void _fail(Object e) => widget.error.value = e is TerminalException ? e.message : '$e';

  Future<void> _send() async {
    final text = _field.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    widget.error.value = null;
    try {
      var o = remote.orchestrator;
      if (o == null) {
        setState(() => _starting = true);
        await remote.startOrchestrator();
        o = await _arrival(const Duration(seconds: 30));
      }
      await remote.prompt(o.key, text);
      // Closed while it went: the prompt is sent all the same, and its draft goes.
      if (mounted) _field.clear();
      unawaited(saveDraft(_draftKey, ''));
    } on Object catch (e) {
      if (mounted) _fail(e);
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _starting = false;
        });
      }
    }
  }

  /// The orchestrator, once the computer reports it (it says hello once omp is up).
  Future<LiveSummary> _arrival(Duration timeout) async {
    final arrived = Completer<LiveSummary>();
    void check() {
      final o = remote.orchestrator;
      if (o != null && !arrived.isCompleted) arrived.complete(o);
    }

    remote.addListener(check);
    check();
    try {
      return await arrived.future.timeout(
        timeout,
        onTimeout: () => throw const TerminalException(
          "The orchestrator didn't start on the computer. Look at its terminal window.",
        ),
      );
    } finally {
      remote.removeListener(check);
    }
  }

  // ---------------------------------------------------------------- voice

  Future<void> _down() async {
    if (_voice != _Voice.off) return;
    _released = false;
    widget.error.value = null;
    setState(() => _voice = _Voice.checking);
    // The language the voice sheet listens in: the phone's choice, else Auto's.
    final language = await voiceLanguage.resolve(voiceSource);
    SpeechCheck check;
    try {
      check = await voiceSource.check(language);
    } on Object {
      check = const SpeechCheck(SpeechStatus.unavailable);
    }
    if (!mounted) return;
    if (check.status != SpeechStatus.ready) {
      widget.error.value = speechProblemText(check, language);
      setState(() => _voice = _Voice.off);
      return;
    }
    // Lifted while it checked: nothing heard.
    if (_released) {
      setState(() => _voice = _Voice.off);
      return;
    }
    unawaited(HapticFeedback.mediumImpact());
    _sub = voiceSource
        .listen(language)
        .listen(
          (e) {
            if (!mounted) return;
            switch (e) {
              case SpeechHeard(:final text):
                setState(() => _live = text);
              case SpeechLevel(:final level):
                setState(() => _level = level);
              case SpeechEnded():
                _finish();
            }
          },
          onDone: _finish,
          onError: (Object _) => _finish(),
        );
    setState(() => _voice = _Voice.listening);
  }

  Future<void> _up() async {
    _released = true;
    if (_voice != _Voice.listening) return;
    setState(() => _voice = _Voice.stopping);
    _stopWait = Timer(const Duration(seconds: 3), _finish);
    try {
      await voiceSource.stop();
    } on Object {
      _finish();
    }
  }

  /// Done listening: what was heard goes into the field, after what's there. Never sends.
  void _finish() {
    if (_voice == _Voice.off || !mounted) return;
    _stopWait?.cancel();
    unawaited(_sub?.cancel());
    _sub = null;
    final heard = _live.trim();
    if (heard.isNotEmpty) {
      final text = appendSpoken(_field.text, heard);
      _field.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _focus.requestFocus();
      unawaited(HapticFeedback.lightImpact());
    }
    setState(() {
      _live = '';
      _level = 0;
      _voice = _Voice.off;
    });
  }

  // ---------------------------------------------------------------- layout

  Widget _chat(LiveSummary? o) {
    final items = [
      for (final i in (o == null ? null : remote.view(o.key))?.items ?? const <LiveItem>[])
        if ((i.kind == ItemKind.user || i.kind == ItemKind.assistant) && i.text.trim().isNotEmpty) i,
    ];
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Ask about the sessions on ${widget.computer ?? 'this computer'}: what’s running, what’s stuck, what each '
            'one did. It can also prompt or stop them.',
            textAlign: TextAlign.center,
            style: TextStyle(color: C.dim, height: 1.5),
          ),
        ),
      );
    }
    final ask = o?.ask;
    return ListView(
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (ask != null)
          Padding(
            key: const ValueKey('orchestrator-answer'),
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text('Needs you: ${ask.text}', style: TextStyle(color: C.warn)),
                ),
                TextButton(onPressed: () => widget.onOpen(o!.key), child: const Text('Answer')),
              ],
            ),
          )
        else if (o?.busy ?? false)
          Padding(
            key: const ValueKey('orchestrator-working'),
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Row(
              children: [
                SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: C.accent)),
                const SizedBox(width: 8),
                Text('Working…', style: TextStyle(color: C.dim)),
              ],
            ),
          ),
        for (final i in items.reversed)
          Padding(
            key: ValueKey(i.id),
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: i.kind == ItemKind.user ? UserBubble(i) : AssistantText(i.text),
          ),
      ],
    );
  }

  Widget _mic() {
    final on = _voice == _Voice.listening || _voice == _Voice.stopping;
    return Semantics(
      identifier: 'orchestrator-mic',
      button: true,
      label: 'Microphone',
      tooltip: 'Hold to talk',
      child: Listener(
        key: const ValueKey('orchestrator-mic'),
        onPointerDown: (_) => unawaited(_down()),
        onPointerUp: (_) => unawaited(_up()),
        onPointerCancel: (_) => unawaited(_up()),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(on ? Icons.mic : Icons.mic_none, color: on ? C.accent : C.dim),
        ),
      ),
    );
  }

  Widget _composer() => SafeArea(
    top: false,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_voice != _Voice.off)
          Semantics(
            identifier: 'orchestrator-live',
            child: Container(
              key: const ValueKey('orchestrator-live'),
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(color: C.field, borderRadius: C.round(12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _live.isEmpty ? 'Listening…' : _live,
                    style: TextStyle(fontSize: 15, height: 1.4, color: _live.isEmpty ? C.dim2 : C.text),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: C.round(2),
                    child: LinearProgressIndicator(
                      value: _level,
                      minHeight: 3,
                      color: C.accent,
                      backgroundColor: C.line2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ValueListenableBuilder(
          valueListenable: widget.error,
          builder: (context, error, _) => error == null
              ? const SizedBox.shrink()
              : Padding(
                  key: const ValueKey('orchestrator-error'),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(error, style: TextStyle(fontSize: 13, color: C.warn, height: 1.4)),
                ),
        ),
        if (_starting)
          Padding(
            key: const ValueKey('orchestrator-starting'),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              'Starting the orchestrator on ${widget.computer ?? 'the computer'}…',
              style: TextStyle(fontSize: 13, color: C.dim, height: 1.4),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Semantics(
                  identifier: 'orchestrator-input',
                  child: TextField(
                    key: const ValueKey('orchestrator-input'),
                    controller: _field,
                    focusNode: _focus,
                    onTapOutside: dismissKeyboard,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(fontSize: 16, height: 1.4),
                    decoration: plainInput.copyWith(
                      hintText: 'Ask the orchestrator…',
                      hintStyle: TextStyle(color: C.dim2),
                      // 48 tall, like the buttons beside it, so one line sits on their center.
                      contentPadding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                  ),
                ),
              ),
              TextFieldTapRegion(child: _mic()),
              TextFieldTapRegion(
                child: ValueListenableBuilder(
                  valueListenable: _field,
                  builder: (context, value, _) {
                    final canSend = value.text.trim().isNotEmpty && !_sending;
                    return Semantics(
                      identifier: 'orchestrator-send',
                      child: IconButton(
                        key: const ValueKey('orchestrator-send'),
                        tooltip: 'Send',
                        onPressed: canSend ? () => unawaited(_send()) : null,
                        icon: _sending
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(Icons.arrow_upward, color: canSend ? C.accent : C.dim2),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final on = _voice != _Voice.off;
    return Semantics(
      identifier: 'orchestrator-sheet',
      container: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        // Held, the microphone lights the whole sheet: it's listening.
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: on ? C.accent.withValues(alpha: .06) : Colors.transparent,
            border: Border.all(color: on ? C.accent : Colors.transparent, width: 2),
            borderRadius: C.round(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListenableBuilder(listenable: remote, builder: (context, _) => _chat(remote.orchestrator)),
              ),
              _composer(),
            ],
          ),
        ),
      ),
    );
  }
}
