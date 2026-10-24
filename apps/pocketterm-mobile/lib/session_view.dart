import 'dart:async';
import 'dart:math' show min;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/chat_images.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/live_activity.dart';
import 'package:pocketterm_core/native.dart' show TooManyActivities;
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';
import 'package:pocketterm_mobile/coach.dart';
import 'package:pocketterm_mobile/terminal_view.dart';
import 'package:url_launcher/url_launcher.dart';

const _mono = TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['Courier'], fontSize: 12, height: 1.35);
const _danger = Color(0xFFFCA5A5);

/// How long a just-launched agent may take to report before the page says so.
const _startWait = Duration(seconds: 20);

/// One coding session, live: its transcript laid out for the phone, what its
/// agent asks, and a composer that prompts it.
class SessionPage extends StatefulWidget {
  const SessionPage({
    required this.remote,
    required this.sessionKey,
    this.starting = false,
    this.offerContinue = false,
    this.autoContinue = false,
    super.key,
  });
  final TerminalRemote remote;
  final String sessionKey;

  /// Just launched: its agent may not have reported yet.
  final bool starting;

  /// It was just restarted from the phone in the middle of a run: a Continue chip above the composer prompts it
  /// to carry on, once.
  final bool offerContinue;

  /// Like [offerContinue], but `continue` is sent as soon as the session can take a prompt, once; the chip shows
  /// only if that fails.
  final bool autoContinue;

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  final _scroll = ScrollController();
  final _field = TextEditingController();
  final _attachments = ChatAttachments();
  late final VoidCallback _unwatch;
  final _openedAt = DateTime.now();

  /// Items ordered before [_anchor] sit above the scroll view's center,
  /// newer ones below it, so arrivals never move what the reader looks at.
  /// Set from the transcript there is at first (again if it starts over).
  int? _anchor;
  String? _anchorEpoch;
  bool _atBottom = true;

  /// The session has been in the computer's state since the page opened.
  bool _seen = false;
  bool _sending = false;
  bool _stopping = false;
  bool _followUp = false;

  /// [SessionPage.offerContinue] until Continue went.
  late bool _continue = widget.offerContinue;

  /// [SessionPage.autoContinue] until `continue` went out.
  late bool _autoContinue = widget.autoContinue;
  bool _loadingOlder = false;

  /// The close button was tapped: the page asks above the composer.
  bool _closing = false;

  /// A close was sent, and the computer hasn't answered yet.
  bool _closeSent = false;

  /// The composer, which toasts keep clear of.
  final GlobalKey _composerKey = GlobalKey();

  /// Tool items showing their output.
  final _expanded = <String>{};

  /// Each item's widget and what it was built from, so a transcript update
  /// rebuilds only the items that changed.
  final _built = <String, (Object, Widget)>{};

  /// Prompts sent from here that haven't come back in the transcript yet, oldest first.
  final _outgoing = <_Outgoing>[];

  /// One of [_outgoing] is on its way to the computer.
  bool get _delivering => _outgoing.any((o) => o.sending);

  TerminalRemote get remote => widget.remote;
  String get key => widget.sessionKey;

  @override
  void initState() {
    super.initState();
    _field.addListener(() => setState(() {}));
    _attachments.addListener(() => setState(() {}));
    _scroll.addListener(() {
      final p = _scroll.position;
      _atBottom = p.pixels >= p.maxScrollExtent - 24;
    });
    _unwatch = remote.watchSession(key);
    if (_autoContinue) {
      remote.addListener(_continueWhenReady);
      WidgetsBinding.instance.addPostFrameCallback((_) => _continueWhenReady());
    }
  }

  @override
  void dispose() {
    _unwatch();
    remote.removeListener(_continueWhenReady);
    _scroll.dispose();
    _field.dispose();
    _attachments.dispose();
    super.dispose();
  }

  /// The terminal window the agent runs in, if it runs in one (a launched one
  /// before it reports: the session's key is its window's).
  String? _windowKey(LiveSummary? s) => s?.window ?? (remote.window(key) != null ? key : null);

  /// Whether there's a [window] and its terminal can do [cap]; one not in the
  /// list yet (just launched) can do everything.
  bool _can(String? window, TermCap cap) => window != null && (remote.window(window)?.can(cap) ?? true);

  /// The session's agent: as it reports, else its window's program, else the
  /// one the computer starts (a just-launched session).
  Agent _agent(LiveSummary? s) => s?.agent ?? remote.window(key)?.agent ?? remote.agent;

  Future<void> _attach(String from) async {
    if (from == 'photos') return await _attachments.pick();
    if (from == 'files') return await _attachments.addFiles(await openFiles());
    if (!await _attachments.paste() && mounted) {
      termToast(context, 'There is no image on the clipboard.', above: _composerKey);
    }
  }

  Future<void> _send({required bool busy}) async {
    final typed = _field.text;
    final text = typed.trim();
    if ((text.isEmpty && _attachments.isEmpty) || _sending || _delivering) return;
    final attached = List.of(_attachments.items);
    // A slash command is typed into the agent's window, where its editor
    // reads it; sent as a prompt, the agent would take it for chat.
    final command = text.startsWith('/');
    if (command && attached.isNotEmpty) {
      return termToast(context, "Slash commands can't take images or files.", above: _composerKey);
    }
    if (command && !_can(_windowKey(remote.session(key)), TermCap.line)) {
      return termToast(context, _noCommands(_agent(remote.session(key))), above: _composerKey);
    }
    final queue = busy && (_followUp || !_agent(remote.session(key)).steers);
    if (!command) return await _prompt(text, attached, followUp: queue);
    setState(() => _sending = true);
    try {
      final before = remote.session(key)?.id;
      await remote.prompt(key, text, followUp: queue);
      // Left meanwhile (back, signed out): the field is gone.
      if (!mounted) return;
      final window = remote.session(key)?.window;
      if (window != null) unawaited(_menuOrScreen(window, before));
      // Only what went: the field stays editable while it goes, and what was
      // typed meanwhile is the next prompt.
      final now = _field.text;
      _field.text = now.startsWith(typed) ? now.substring(typed.length).trimLeft() : now;
      _atBottom = true;
    } on Object catch (e) {
      if (mounted) termToast(context, e, above: _composerKey);
    }
    if (mounted) setState(() => _sending = false);
  }

  /// Sends [text] and [attached] as the person's message, which shows at once at the bottom of the transcript
  /// while the field and the attachments are free for the next one.
  Future<void> _prompt(String text, List<ChatAttachment> attached, {required bool followUp}) async {
    // A prompt of their own replaces the `continue` a restart would send, and says what comes next instead of
    // Continue.
    if (_autoContinue) {
      _autoContinue = false;
      remote.removeListener(_continueWhenReady);
    }
    _continue = false;
    final o = _Outgoing(text, attached, followUp: followUp, transcript: remote.view(key));
    _field.clear();
    _attachments.removeSent(attached);
    _atBottom = true;
    _outgoing.add(o);
    await _deliver(o);
  }

  /// Sends [o] (again): a failure stays on its bubble, with why.
  Future<void> _deliver(_Outgoing o) async {
    setState(() {
      o
        ..sending = true
        ..problem = null;
    });
    try {
      await remote.prompt(
        key,
        o.text,
        images: [
          for (final a in o.attachments)
            if (a is ChatImage) a.bytes,
        ],
        files: [
          for (final a in o.attachments)
            if (a is ChatFile) (name: a.name, mime: a.mime, bytes: a.bytes),
        ],
        followUp: o.followUp,
      );
      // Followed from here on (Lock Screen, Android's notifications), as working.
      final s = remote.session(key);
      if (s != null) unawaited(remote.activities?.prompted(key, title: _title(s)));
    } on Object catch (e) {
      o.problem = e is TerminalException ? e.message : '$e';
    }
    o.sending = false;
    if (mounted) setState(() {});
  }

  /// Prompts `continue`: the run a restart from the phone stopped carries on. Once; again only if it didn't go.
  Future<void> _sendContinue() async {
    setState(() => _continue = false);
    try {
      await remote.prompt(key, 'continue');
      final s = remote.session(key);
      if (s != null) unawaited(remote.activities?.prompted(key, title: _title(s)));
      _atBottom = true;
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _continue = true);
      termToast(context, e, above: _composerKey);
    }
  }

  /// [SessionPage.autoContinue]: prompts `continue` once the session is there, at rest, and the phone is online.
  void _continueWhenReady() {
    if (!_autoContinue || !mounted) return;
    final s = remote.session(key);
    if (!remote.online || s == null || s.busy || _sending) return;
    _autoContinue = false;
    remote.removeListener(_continueWhenReady);
    unawaited(_sendContinue());
  }

  /// Why [agent]'s slash commands can't be sent from here.
  static String _noCommands(Agent agent) =>
      'Slash commands are typed into ${agent.label}’s terminal window, and PocketTerm can’t reach this one: it isn’t in '
      'kitty, tmux, WezTerm or Ghostty. Run them on the computer.';

  Future<void> _close(TermWindow w) async {
    setState(() => _closeSent = true);
    final closed = await closeWindow(context, remote, w);
    if (!mounted) return;
    setState(() => _closing = _closeSent = false);
    if (closed) await Navigator.of(context).maybePop();
  }

  /// A command's picker (/resume, /model, /tree …) shows here as a menu once
  /// the computer has read it off the agent's screen; when none comes (a command
  /// without one, or one the computer can't read), its screen opens instead. A
  /// command that renewed the session (/new, /clear) shows its result here, so
  /// nothing opens: [before] is the session's id when it was sent.
  Future<void> _menuOrScreen(String window, String? before) async {
    bool renewed() => before != null && (remote.session(key)?.id ?? before) != before;
    for (var tick = 0; tick < 12; tick++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted || (remote.session(key)?.ask?.isMenu ?? false) || renewed()) return;
    }
    if (!mounted || renewed()) return;
    if ((ModalRoute.of(context)?.isCurrent ?? false) && _can(window, TermCap.read)) {
      openWindow(context, remote, window);
    }
  }

  String _title(LiveSummary s) => s.title.isNotEmpty ? s.title : baseName(s.cwd);

  /// Puts `/name ` in the field, the cursor after it.
  void _complete(LiveCommand c) {
    final text = '/${c.name} ';
    _field.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Slash commands go to the agent's terminal window: the [matches] while the
  /// name is typed, or a word that they can't run without one that takes a line.
  Widget? _commands(List<LiveCommand> matches, {required bool noWindow, required Agent agent}) {
    if (noWindow) {
      return Padding(
        key: const ValueKey('commands-need-window'),
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
        child: Text(_noCommands(agent), style: const TextStyle(color: C.dim, fontSize: 12)),
      );
    }
    if (matches.isEmpty) return null;
    // Part of the field for tap-outside: picking one keeps the keyboard up.
    return TextFieldTapRegion(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in matches)
              InkWell(
                key: ValueKey('command-${c.name}'),
                canRequestFocus: false,
                borderRadius: BorderRadius.circular(6),
                onTap: () => _complete(c),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '/${c.name}',
                          style: const TextStyle(color: C.text, fontWeight: FontWeight.w600),
                        ),
                        if (c.description.isNotEmpty)
                          TextSpan(
                            text: '  ${c.description}',
                            style: const TextStyle(color: C.dim),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleFollow(LiveActivities activities, LiveSummary s) async {
    if (activities.following(key)) return await activities.stop(key);
    String? problem;
    try {
      if (!await activities.follow(key, title: _title(s))) {
        problem = isIos
            ? 'Live Activities are off for PocketTerm: turn them on in Settings → PocketTerm.'
            : 'Notifications are off for PocketTerm: turn them on in Settings → Apps → PocketTerm.';
      }
    } on TooManyActivities {
      problem =
          'Your iPhone shows only a few Live Activities at once. Stop following another session, or end one on the '
          'Lock Screen, then try again.';
    }
    if (problem != null && mounted) termToast(context, problem, above: _composerKey);
  }

  Future<void> _stop() async {
    setState(() => _stopping = true);
    try {
      await remote.abort(key);
    } on Object catch (e) {
      if (mounted) termToast(context, e, above: _composerKey);
    }
    if (mounted) setState(() => _stopping = false);
  }

  Future<void> _older() async {
    setState(() => _loadingOlder = true);
    try {
      await remote.older(key);
    } on Object catch (e) {
      if (mounted) termToast(context, e, above: _composerKey);
    }
    if (mounted) setState(() => _loadingOlder = false);
  }

  void _followBottom() {
    if (!_atBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final p = _scroll.position;
      if (p.pixels != p.maxScrollExtent) _scroll.jumpTo(p.maxScrollExtent);
    });
  }

  // ---------------------------------------------------------------- items

  Widget _item(LiveItem i) {
    final open = _expanded.contains(i.id);
    final made = (i.kind, i.text, i.images, i.tool, i.title, i.args, i.output, i.status, open);
    final hit = _built[i.id];
    if (hit != null && hit.$1 == made) return hit.$2;
    final w = KeyedSubtree(
      key: ValueKey(i.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: switch (i.kind) {
          ItemKind.user => _UserBubble(i),
          ItemKind.assistant => _AssistantText(i.text),
          ItemKind.tool => _ToolCard(
            i,
            open: open,
            onTap: () => setState(() => open ? _expanded.remove(i.id) : _expanded.add(i.id)),
          ),
          ItemKind.notice => _Notice(
            i.text,
            open: open,
            onTap: () => setState(() => open ? _expanded.remove(i.id) : _expanded.add(i.id)),
          ),
        },
      ),
    );
    _built[i.id] = (made, w);
    return w;
  }

  Widget _transcript(LiveView? v, LiveSummary? s, {required bool ended}) {
    final items = v?.items ?? const <LiveItem>[];
    // Those whose item has come in show as it, in their place.
    if (v != null && _outgoing.isNotEmpty) _outgoing.removeWhere(_cameBack(_outgoing, v).contains);
    if (v != null && items.isNotEmpty && (_anchor == null || _anchorEpoch != v.epoch)) {
      _anchor = items.last.order + 1;
      _anchorEpoch = v.epoch;
      _atBottom = true;
      _built.clear();
    } else if (_built.length > 2 * items.length + 64) {
      // Items the view no longer holds (dropped, a fresh catch-up): their widgets go too.
      final ids = {for (final i in items) i.id};
      _built.removeWhere((id, _) => !ids.contains(id));
    }
    if (items.isEmpty && _outgoing.isEmpty) {
      final agent = _agent(s).label;
      final starting = widget.starting && !_seen;
      final late = DateTime.now().difference(_openedAt) > _startWait;
      final text = starting
          ? (late
                ? "$agent hasn't reported yet. It may be asking something on its screen first (like whether to "
                      'trust this folder): open the screen to answer.'
                : 'Starting $agent…')
          : ended
          ? 'This session has ended.'
          : v != null
          ? 'Nothing yet. Prompt $agent below.'
          : remote.online
          ? 'Loading…'
          : 'Not on this phone yet.';
      final window = starting && _can(_windowKey(s), TermCap.read) ? _windowKey(s) : null;
      return Center(
        // Scrolls when the room is short (keyboard up, landscape, large text).
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: C.dim, height: 1.5),
              ),
              if (window != null && remote.online) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () => openWindow(context, remote, window),
                  icon: const Icon(Icons.terminal, size: 18),
                  label: const Text('Open its screen'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    // First item at or after the anchor.
    var lo = 0;
    var hi = items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (items[mid].order < _anchor!) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final above = lo;
    final earlier = v?.older ?? false;
    const center = ValueKey('center');
    _followBottom();
    return SelectionArea(
      child: CustomScrollView(
        controller: _scroll,
        center: center,
        // The center at the bottom: the newest item shows first, and a short
        // transcript sits down by the composer.
        anchor: 1,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          // Before the center: laid out upwards from it, newest first.
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => i < above ? _item(items[above - 1 - i]) : _earlierButton(),
              childCount: above + (earlier ? 1 : 0),
            ),
          ),
          SliverList(
            key: center,
            delegate: SliverChildBuilderDelegate((_, i) => _item(items[above + i]), childCount: items.length - above),
          ),
          // Sent from here, until each comes back in the transcript.
          if (_outgoing.isNotEmpty)
            SliverList(
              delegate: SliverChildListDelegate([
                for (final o in _outgoing)
                  Padding(
                    key: ObjectKey(o),
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                    child: _OutgoingBubble(o, key: const ValueKey('outgoing'), onRetry: () => unawaited(_deliver(o))),
                  ),
              ]),
            ),
          if (s != null && s.busy && s.ask == null)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                    SizedBox(width: 10),
                    Text('Working…', style: TextStyle(fontSize: 13, color: C.dim)),
                  ],
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        ],
      ),
    );
  }

  Widget _earlierButton() => SelectionContainer.disabled(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Center(
        child: _loadingOlder
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : TextButton(
                key: const ValueKey('earlier'),
                onPressed: remote.online ? () => unawaited(_older()) : null,
                child: const Text('Earlier messages'),
              ),
      ),
    ),
  );

  // --------------------------------------------------------------- chrome

  Widget _status(LiveSummary? s) {
    final parts = <InlineSpan>[];
    if (s == null) {
      parts.add(TextSpan(text: _agent(s).label));
    } else {
      parts.add(
        TextSpan(
          text: s.ask != null
              ? 'Needs you'
              : s.busy
              ? 'Working…'
              : 'Idle${s.at == null ? '' : ' · ${ago(s.at!)}'}',
          style: TextStyle(color: s.ask != null || s.busy ? sessionColor(s) : null),
        ),
      );
      if (s.model.isNotEmpty) parts.add(TextSpan(text: ' · ${s.model}'));
      if (s.ctx != null) parts.add(TextSpan(text: ' · ${s.ctx}%'));
    }
    return Text.rich(
      TextSpan(children: parts),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: C.dim),
    );
  }

  Widget _banner(String text, {List<Widget> actions = const []}) => Container(
    color: C.bar,
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
    child: SafeArea(
      top: false,
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 14, color: C.dim)),
          ),
          ...actions,
        ],
      ),
    ),
  );

  Widget _composer(LiveSummary? s, {required bool online}) {
    final busy = s?.busy ?? false;
    final agent = _agent(s);
    // One at a time, in order: the next waits until the computer has the one sending.
    final canSend = online && !_sending && !_delivering && (_field.text.trim().isNotEmpty || !_attachments.isEmpty);
    final slash = _field.text.startsWith('/');
    final commanding = online && s != null && slash;
    final noWindow = commanding && !_can(_windowKey(s), TermCap.line);
    final matches = commanding && !noWindow ? matchCommands(s.commands, _field.text) : const <LiveCommand>[];
    final commands = _commands(matches, noWindow: noWindow, agent: agent);
    return Container(
      key: _composerKey,
      decoration: const BoxDecoration(
        color: C.bar,
        border: Border(top: BorderSide(color: C.line)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ?commands,
            Reveal(
              visible: _continue && online && s != null && !busy,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 0, 4),
                  child: TextFieldTapRegion(
                    child: ActionChip(
                      key: const ValueKey('continue'),
                      avatar: const Icon(Icons.play_arrow_rounded, size: 18, color: C.accent),
                      label: const Text('Continue'),
                      tooltip: 'Carry on with what it was doing',
                      onPressed: () => unawaited(_sendContinue()),
                    ),
                  ),
                ),
              ),
            ),
            Reveal(
              visible: busy && online,
              child: TextFieldTapRegion(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 0, 2),
                  child: Row(
                    children: [
                      // An agent that can't steer queues every prompt while busy.
                      if (agent.steers)
                        CoachTarget(
                          tip: Tip.queue,
                          radius: 10,
                          padding: 2,
                          child: FilterChip(
                            key: const ValueKey('follow-up'),
                            label: const Text('Queue', style: TextStyle(fontSize: 12)),
                            tooltip: 'Off: the prompt steers ${agent.label} now',
                            selected: _followUp,
                            showCheckmark: true,
                            visualDensity: VisualDensity.compact,
                            onSelected: (v) => setState(() => _followUp = v),
                          ),
                        ),
                      const Spacer(),
                      TextButton.icon(
                        key: const ValueKey('stop'),
                        onPressed: _stopping ? null : () => unawaited(_stop()),
                        icon: const Icon(Icons.stop_circle_outlined, size: 18, color: _danger),
                        label: const Text('Stop', style: TextStyle(color: _danger)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8),
              child: AttachmentStrip(attachments: _attachments, top: 6),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                TextFieldTapRegion(
                  child: PopupMenuButton<String>(
                    tooltip: 'Attach images or files',
                    enabled: online && _attachments.room > 0,
                    icon: Icon(Icons.attach_file, color: online && _attachments.room > 0 ? C.dim : C.dim2),
                    color: C.bar,
                    onSelected: (from) => unawaited(_attach(from)),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'paste', child: Text('Paste image')),
                      PopupMenuItem(value: 'photos', child: Text('Choose from Photos')),
                      PopupMenuItem(value: 'files', child: Text('Choose from Files')),
                    ],
                  ),
                ),
                Expanded(
                  // A hardware keyboard's Tab takes the first suggestion.
                  child: CallbackShortcuts(
                    bindings: {
                      if (matches.isNotEmpty)
                        const SingleActivator(LogicalKeyboardKey.tab): () => _complete(matches.first),
                    },
                    child: CoachTarget(
                      tip: Tip.slash,
                      radius: 12,
                      // Named for UI tests: below Android 9 Flutter reads no text field's hint.
                      child: Semantics(
                        identifier: 'session-input',
                        child: TextField(
                          key: const ValueKey('session-input'),
                          onTapOutside: dismissKeyboard,
                          controller: _field,
                          minLines: 1,
                          maxLines: 6,
                          enabled: online,
                          // A command's name isn't a word to correct or capitalize.
                          autocorrect: !slash,
                          enableSuggestions: !slash,
                          textCapitalization: slash ? TextCapitalization.none : TextCapitalization.sentences,
                          style: const TextStyle(fontSize: 16, height: 1.4),
                          decoration: plainInput.copyWith(
                            hintText: busy
                                ? (_followUp || !agent.steers ? 'Queue a prompt…' : 'Steer ${agent.label}…')
                                : 'Prompt ${agent.label}…',
                            hintStyle: const TextStyle(color: C.dim2),
                            // 48 tall, like the buttons either side, so one line sits on their center.
                            contentPadding: const EdgeInsets.symmetric(vertical: 13),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Part of the field for tap-outside: sending keeps the
                // keyboard up.
                TextFieldTapRegion(
                  child: IconButton(
                    key: const ValueKey('session-send'),
                    tooltip: 'Send',
                    onPressed: canSend ? () => unawaited(_send(busy: busy)) : null,
                    icon: _sending
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.arrow_upward, color: canSend ? C.accent : C.dim2),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([remote, remote.activities]),
    builder: (context, _) {
      final s = remote.session(key);
      if (s != null) _seen = true;
      final v = remote.view(key);
      final online = remote.online;
      final ended = online && !remote.fromCache && s == null && (_seen || !widget.starting);
      final windowKey = _windowKey(s);
      final window = windowKey == null ? null : remote.window(windowKey);
      final title = s == null ? (window?.title.isNotEmpty ?? false ? window!.title : _agent(s).label) : _title(s);
      final note = linkNote(remote);
      final ask = s?.ask;
      final readable = _can(windowKey, TermCap.read);
      void screen() => openWindow(context, remote, windowKey!);
      return Scaffold(
        appBar: AppBar(
          // Tight: the title is two lines (the session and its state).
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
              _status(s),
            ],
          ),
          actions: [
            if (remote.activities case final activities? when s != null)
              CoachTarget(
                tip: Tip.follow,
                radius: 24,
                padding: 0,
                child: IconButton(
                  key: const ValueKey('follow-lock-screen'),
                  tooltip: switch ((isIos, activities.following(key))) {
                    (true, true) => 'Stop following on Lock Screen',
                    (true, false) => 'Follow on Lock Screen',
                    (false, true) => 'Stop following in notifications',
                    (false, false) => 'Follow in notifications',
                  },
                  onPressed: () => unawaited(_toggleFollow(activities, s)),
                  icon: activities.following(key)
                      ? const Icon(Icons.lock_clock, color: C.accent)
                      : const Icon(Icons.lock_clock_outlined, color: C.dim),
                ),
              ),
            if (readable)
              CoachTarget(
                tip: Tip.openScreen,
                radius: 24,
                padding: 0,
                child: IconButton(
                  key: const ValueKey('open-screen'),
                  tooltip: 'Screen',
                  onPressed: screen,
                  icon: const Icon(Icons.terminal, color: C.dim),
                ),
              ),
            if (window != null && online && window.can(TermCap.close))
              IconButton(
                key: const ValueKey('close-window'),
                tooltip: 'Close window',
                onPressed: _closeSent ? null : () => setState(() => _closing = true),
                icon: const Icon(Icons.close, color: C.dim),
              ),
          ],
        ),
        // Small room (keyboard up on a small phone, landscape, large text): what's under the transcript takes at
        // most four fifths of it and scrolls, the composer last, instead of running off the screen.
        body: LayoutBuilder(
          builder: (context, box) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Reveal(visible: note != null, child: note ?? const SizedBox.shrink()),
              Expanded(child: _transcript(v, s, ended: ended)),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: box.maxHeight * .8),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Reveal(
                        visible: _closing && window != null && online && !ended,
                        child: window == null
                            ? const SizedBox.shrink()
                            : CloseConfirm(
                                remote: remote,
                                window: window,
                                onCancel: () => setState(() => _closing = false),
                                onClose: () => unawaited(_close(window)),
                                closing: _closeSent,
                              ),
                      ),
                      if (ended)
                        _banner(
                          'This session has ended.',
                          actions: [if (readable) TextButton(onPressed: screen, child: const Text('Screen'))],
                        )
                      else ...[
                        Reveal(
                          visible: ask != null,
                          child: ask == null
                              ? const SizedBox.shrink()
                              : ask.isMenu
                              ? _MenuCard(
                                  key: ValueKey('ask-${ask.id}'),
                                  remote: remote,
                                  session: key,
                                  window: _can(windowKey, TermCap.keys) ? windowKey : null,
                                  ask: ask,
                                  onScreen: readable ? screen : null,
                                  toastAbove: _composerKey,
                                )
                              : _AskCard(
                                  key: ValueKey('ask-${ask.id}'),
                                  remote: remote,
                                  session: key,
                                  ask: ask,
                                  onScreen: readable ? screen : null,
                                  toastAbove: _composerKey,
                                ),
                        ),
                        _composer(s, online: online && (s != null || !widget.starting)),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// A prompt sent from the page: shown as the person's message until its item comes back in the transcript, and
/// sent again as it is.
class _Outgoing {
  _Outgoing(this.text, this.attachments, {required this.followUp, required LiveView? transcript})
    : _epoch = transcript?.epoch,
      _last = transcript == null || transcript.items.isEmpty ? -1 : transcript.items.last.order,
      _seen = {
        for (final i in transcript?.items ?? const <LiveItem>[])
          if (i.kind == ItemKind.user) i.id,
      };

  final String text;
  final List<ChatAttachment> attachments;

  /// Sent to wait for the run to end.
  final bool followUp;

  /// On its way to the computer.
  bool sending = true;

  /// Why it wasn't sent, when it wasn't.
  String? problem;

  /// The transcript when it went: the person's items there already aren't this one coming back.
  final String? _epoch;
  final int _last;
  final Set<String> _seen;

  /// Whether user item [i] of a transcript in [epoch] came after this went.
  bool _sentBefore(LiveItem i, String epoch) => !_seen.contains(i.id) && (epoch != _epoch || i.order > _last);
}

/// [s] with its runs of whitespace as single spaces, trimmed: how a prompt and the agent's copy of it compare.
String _plain(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Which of [outgoing] (oldest first) have come back in transcript [v]: each is the first of the person's items
/// since it went, in order, whose text holds its own (the computer may add to it: files named as @path).
Set<_Outgoing> _cameBack(List<_Outgoing> outgoing, LiveView v) {
  final items = v.items;
  // From just after the oldest went; from the start once the transcript started over.
  var start = 0;
  if (outgoing.every((o) => o._epoch == v.epoch)) {
    final last = outgoing.map((o) => o._last).reduce(min);
    start = items.length;
    while (start > 0 && items[start - 1].order > last) {
      start--;
    }
  }
  final back = Set<_Outgoing>.identity();
  var next = start;
  for (final o in outgoing) {
    final want = _plain(o.text);
    for (var j = next; j < items.length; j++) {
      final i = items[j];
      if (i.kind != ItemKind.user || !o._sentBefore(i, v.epoch) || !_plain(i.text).contains(want)) continue;
      back.add(o);
      next = j + 1;
      break;
    }
  }
  return back;
}

/// A prompt sent from the page, shown as the person's own until its item comes back: dimmed, with a spinner, while
/// it goes. One that didn't go says why, and a tap sends it again.
class _OutgoingBubble extends StatelessWidget {
  const _OutgoingBubble(this.message, {required this.onRetry, super.key});
  final _Outgoing message;
  final VoidCallback onRetry;

  static const _note = TextStyle(fontSize: 12, color: C.dim);

  @override
  Widget build(BuildContext context) {
    final o = message;
    final problem = o.sending ? null : o.problem;
    return GestureDetector(
      onTap: problem != null ? onRetry : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedOpacity(
            opacity: o.sending ? .6 : 1,
            duration: const Duration(milliseconds: 200),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .82),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: BoxDecoration(
                  color: C.sel,
                  borderRadius: BorderRadius.circular(14),
                  border: problem != null ? Border.all(color: _danger.withValues(alpha: .6)) : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (o.attachments.isNotEmpty)
                      AttachmentThumbs(o.attachments, size: 48, alignment: WrapAlignment.end),
                    if (o.text.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: o.attachments.isEmpty ? 0 : 6),
                        child: Text(o.text, style: const TextStyle(fontSize: 15, height: 1.4)),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (o.sending)
            const Padding(
              key: ValueKey('outgoing-sending'),
              padding: EdgeInsets.only(top: 4, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
                  SizedBox(width: 6),
                  Text('Sending…', style: _note),
                ],
              ),
            )
          else if (problem != null)
            Padding(
              key: const ValueKey('outgoing-failed'),
              padding: const EdgeInsets.only(top: 4, right: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(problem, textAlign: TextAlign.end, maxLines: 3, overflow: TextOverflow.ellipsis, style: _note),
                  const Text('Not sent. Tap to retry', style: TextStyle(fontSize: 12, color: _danger)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble(this.item);
  final LiveItem item;

  @override
  Widget build(BuildContext context) {
    final n = item.images;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .82),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(color: C.sel, borderRadius: BorderRadius.circular(14)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.text.isNotEmpty) Text(item.text, style: const TextStyle(fontSize: 15, height: 1.4)),
              if (n > 0)
                Padding(
                  padding: EdgeInsets.only(top: item.text.isEmpty ? 0 : 4),
                  child: Text('⊕ $n image${n == 1 ? '' : 's'}', style: const TextStyle(fontSize: 12, color: C.dim)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantText extends StatelessWidget {
  const _AssistantText(this.text);
  final String text;

  static const _code = TextStyle(fontFamily: 'Menlo', fontSize: 12.5, color: Color(0xFFD7DAE3));

  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: text,
    // A line break in the answer is one on screen, as the agent's terminal shows it.
    softLineBreak: true,
    onTapLink: (_, href, _) {
      final uri = href == null ? null : Uri.tryParse(href);
      if (uri != null) unawaited(launchUrl(uri));
    },
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: const TextStyle(fontSize: 15, height: 1.5, color: C.text),
      listBullet: const TextStyle(fontSize: 15, height: 1.5, color: C.dim),
      a: const TextStyle(color: C.accent),
      code: _code.copyWith(backgroundColor: C.field),
      codeblockPadding: const EdgeInsets.all(10),
      codeblockDecoration: BoxDecoration(
        color: C.field,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: C.line),
      ),
      blockquoteDecoration: const BoxDecoration(
        border: Border(left: BorderSide(color: C.line2, width: 2)),
      ),
      blockSpacing: 10,
    ),
  );
}

/// The agent's own lines in the transcript ("Interrupted", a finished background
/// job). A short one sits centered; a long one is left-aligned and folded to
/// three lines until tapped.
class _Notice extends StatelessWidget {
  const _Notice(this.text, {required this.open, required this.onTap});
  final String text;
  final bool open;
  final VoidCallback onTap;

  static const _style = TextStyle(fontSize: 12, color: C.dim2, height: 1.4);

  @override
  Widget build(BuildContext context) {
    if (text.length <= 80 && !text.contains('\n')) return Text(text, textAlign: TextAlign.center, style: _style);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.only(left: 10),
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: C.line2, width: 2)),
        ),
        child: AnimatedSize(
          duration: Motion.fast,
          curve: Motion.fold,
          alignment: Alignment.topCenter,
          child: Text(text, maxLines: open ? null : 3, overflow: open ? null : TextOverflow.ellipsis, style: _style),
        ),
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard(this.item, {required this.open, required this.onTap});
  final LiveItem item;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final i = item;
    final what = i.title.isNotEmpty ? i.title : i.args;
    final status = switch (i.status) {
      ToolStatus.running => const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
      ToolStatus.ok => const Icon(Icons.check, size: 14, color: C.ok),
      ToolStatus.error => const Icon(Icons.close, size: 14, color: _danger),
    };
    return Container(
      decoration: BoxDecoration(
        color: C.field,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: i.status == ToolStatus.error ? const Color(0xFF5B2A2A) : C.line),
      ),
      child: AnimatedSize(
        duration: Motion.fast,
        curve: Motion.fold,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectionContainer.disabled(
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Row(
                    children: [
                      SizedBox(width: 16, child: Center(child: status)),
                      const SizedBox(width: 8),
                      Text(
                        i.tool,
                        style: _mono.copyWith(fontWeight: FontWeight.w600, color: C.text),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          what,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _mono.copyWith(color: C.dim),
                        ),
                      ),
                      Icon(open ? Icons.expand_less : Icons.expand_more, size: 16, color: C.dim2),
                    ],
                  ),
                ),
              ),
            ),
            if (open) ...[
              const Divider(height: 1, color: C.line),
              if (i.title.isNotEmpty && i.args.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                  child: Text(i.args, style: _mono.copyWith(color: C.dim)),
                ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Text(
                  i.output.isEmpty ? (i.status == ToolStatus.running ? '…' : 'No output.') : i.output,
                  softWrap: false,
                  style: _mono.copyWith(color: const Color(0xFFD7DAE3)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What the agent asks, answered from the phone: the `ask` tool's questions,
/// an approval, or the plan review at the end of plan mode (its options as
/// the computer read them off the agent's screen; the plan itself is read there).
class _AskCard extends StatefulWidget {
  const _AskCard({
    required this.remote,
    required this.session,
    required this.ask,
    this.onScreen,
    this.toastAbove,
    super.key,
  });
  final TerminalRemote remote;
  final String session;
  final LiveAsk ask;

  /// Opens the session's screen; null when it has none.
  final VoidCallback? onScreen;

  /// The composer below, which toasts keep clear of.
  final GlobalKey? toastAbove;

  @override
  State<_AskCard> createState() => _AskCardState();
}

class _AskCardState extends State<_AskCard> {
  late final List<Set<int>> _picks = [for (final _ in widget.ask.questions ?? const []) <int>{}];
  late final List<TextEditingController> _other = [
    for (final _ in widget.ask.questions ?? const []) TextEditingController(),
  ];
  bool _sending = false;

  /// The plan review option being sent.
  int? _planPick;

  /// Sent; the card stays until the agent moves on.
  bool _sent = false;

  @override
  void dispose() {
    for (final c in _other) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _complete {
    final qs = widget.ask.questions!;
    for (final (i, q) in qs.indexed) {
      final custom = _other[i].text.trim().isNotEmpty ? 1 : 0;
      if (q.multi ? _picks[i].length + custom == 0 : _picks[i].length + custom != 1) return false;
    }
    return true;
  }

  Future<void> _answer({bool approve = false, int? plan}) async {
    setState(() {
      _sending = true;
      _planPick = plan;
    });
    try {
      final ask = widget.ask;
      await widget.remote.answer(
        widget.session,
        ask,
        approve: approve,
        answers: [
          if (plan != null)
            LiveAnswer(picks: [plan])
          else if (!ask.isApproval)
            for (final (i, p) in _picks.indexed)
              LiveAnswer(
                picks: p.toList()..sort(),
                custom: _other[i].text.trim().isEmpty ? null : _other[i].text.trim(),
              ),
        ],
      );
      _sent = true;
    } on Object catch (e) {
      if (mounted) termToast(context, e, above: widget.toastAbove);
    }
    if (mounted) setState(() => _sending = false);
  }

  Widget _question(int i, LiveQuestion q) {
    final busy = _sending || _sent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (q.header.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: C.sel, borderRadius: BorderRadius.circular(6)),
            child: Text(q.header, style: const TextStyle(fontSize: 11, color: C.accent)),
          ),
        Text(q.question, style: const TextStyle(fontSize: 15, height: 1.4)),
        if (q.multi)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text('Pick any', style: TextStyle(fontSize: 12, color: C.dim2)),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (o, label) in q.options.indexed)
              ChoiceChip(
                key: ValueKey('ask-$i-$o'),
                label: Text(q.recommended == o ? '$label ★' : label),
                selected: _picks[i].contains(o),
                showCheckmark: q.multi,
                onSelected: busy
                    ? null
                    : (on) => setState(() {
                        if (!q.multi) {
                          _picks[i].clear();
                          _other[i].clear();
                        }
                        on ? _picks[i].add(o) : _picks[i].remove(o);
                      }),
              ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _other[i],
          enabled: !busy,
          onTapOutside: dismissKeyboard,
          onChanged: (t) => setState(() {
            if (!q.multi && t.trim().isNotEmpty) _picks[i].clear();
          }),
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Other…',
            hintStyle: const TextStyle(color: C.dim2),
            isDense: true,
            filled: true,
            fillColor: C.field,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final agent = (widget.remote.session(widget.session)?.agent ?? widget.remote.agent).label;
    final ask = widget.ask;
    final busy = _sending || _sent;
    final online = widget.remote.online;
    final spinner = _sending
        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
        : null;
    final Widget body;
    final List<Widget> buttons;
    if (ask.isPlan) {
      final screen = widget.onScreen;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Plan ready', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          if (ask.title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(ask.title, style: _mono.copyWith(color: C.dim)),
            ),
          if (ask.options.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                screen == null
                    ? 'Answer it on the computer: PocketTerm can’t read this terminal.'
                    : '$agent is waiting on its screen',
                key: const ValueKey('plan-waiting'),
                style: const TextStyle(fontSize: 13, color: C.dim),
              ),
            ),
          for (final (i, label) in ask.options.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(
                key: ValueKey('plan-$i'),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                onPressed: busy || !online ? null : () => unawaited(_answer(plan: i)),
                child: Row(
                  children: [
                    Expanded(child: Text(label, style: const TextStyle(fontSize: 14, height: 1.3))),
                    if (_sending && _planPick == i) ...[const SizedBox(width: 8), spinner!],
                  ],
                ),
              ),
            ),
        ],
      );
      buttons = [
        if (screen != null)
          TextButton.icon(
            key: ValueKey(ask.options.isEmpty ? 'plan-screen' : 'view-plan'),
            onPressed: screen,
            icon: const Icon(Icons.terminal, size: 18),
            label: Text(ask.options.isEmpty ? 'Screen' : 'View plan'),
          ),
      ];
    } else if (ask.isApproval) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Approve ${ask.tool}?', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          if (ask.summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(ask.summary, style: _mono.copyWith(color: C.dim)),
            ),
        ],
      );
      buttons = [
        OutlinedButton(
          key: const ValueKey('deny'),
          onPressed: busy || !online ? null : () => unawaited(_answer()),
          child: const Text('Deny'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          key: const ValueKey('approve'),
          onPressed: busy || !online ? null : () => unawaited(_answer(approve: true)),
          child: spinner ?? const Text('Approve'),
        ),
      ];
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, q) in ask.questions!.indexed) ...[if (i > 0) const SizedBox(height: 16), _question(i, q)],
        ],
      );
      buttons = [
        FilledButton(
          key: const ValueKey('answer'),
          onPressed: busy || !online || !_complete ? null : () => unawaited(_answer()),
          child: spinner ?? Text(_sent ? 'Answered' : 'Answer'),
        ),
      ];
    }
    return Container(
      // Of what the keyboard leaves: the composer below stays on screen.
      constraints: BoxConstraints(
        maxHeight: (MediaQuery.sizeOf(context).height - MediaQuery.viewInsetsOf(context).bottom) * .45,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF221F17),
        border: Border(top: BorderSide(color: Color(0xFF4A3F1F))),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('$agent needs you', style: const TextStyle(fontSize: 12, color: C.warn)),
            ),
            body,
            const SizedBox(height: 10),
            // Large text: the buttons go on two lines rather than past the edge.
            Wrap(alignment: WrapAlignment.end, runSpacing: 8, children: buttons),
          ],
        ),
      ),
    );
  }
}

/// A picker a slash command opened in the agent's terminal UI (/resume, /model,
/// /tree …), as the computer read it off the screen: its items to pick from, a
/// search when it has one, Cancel (Esc) and the screen itself.
class _MenuCard extends StatefulWidget {
  const _MenuCard({
    required this.remote,
    required this.session,
    required this.window,
    required this.ask,
    this.onScreen,
    this.toastAbove,
    super.key,
  });
  final TerminalRemote remote;
  final String session;

  /// The terminal window the agent runs in, for Esc; null when it can't
  /// press keys.
  final String? window;
  final LiveAsk ask;
  final VoidCallback? onScreen;

  /// The composer below, which toasts keep clear of.
  final GlobalKey? toastAbove;

  @override
  State<_MenuCard> createState() => _MenuCardState();
}

class _MenuCardState extends State<_MenuCard> {
  final _search = TextEditingController();
  Timer? _searchSoon;

  /// The item being picked, or -1 for Cancel.
  int? _busy;

  /// Put away here (no keys to press Esc with); a new picker shows again.
  bool _hidden = false;

  @override
  void dispose() {
    _searchSoon?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _do(int what, Future<void> Function() action) async {
    setState(() => _busy = what);
    try {
      await action();
    } on Object catch (e) {
      if (mounted) termToast(context, e, above: widget.toastAbove);
    }
    if (mounted) setState(() => _busy = null);
  }

  void _pick(int i) => unawaited(
    _do(
      i,
      () => widget.remote.answer(
        widget.session,
        widget.ask,
        answers: [
          LiveAnswer(picks: [i]),
        ],
      ),
    ),
  );

  /// What's typed goes to the picker's search once typing pauses.
  void _searchChanged(String text) {
    _searchSoon?.cancel();
    _searchSoon = Timer(const Duration(milliseconds: 300), () async {
      try {
        await widget.remote.answer(widget.session, widget.ask, answers: [LiveAnswer(custom: text)]);
      } on Object catch (e) {
        if (mounted) termToast(context, e, above: widget.toastAbove);
      }
    });
  }

  Widget _item(int i, MenuItem item, {required bool enabled}) {
    final current = i == widget.ask.selected;
    return Material(
      key: ValueKey('menu-$i'),
      color: current ? C.sel : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? () => _pick(i) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.3)),
                    if (item.detail.isNotEmpty)
                      Text(
                        item.detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: C.dim, height: 1.3),
                      ),
                  ],
                ),
              ),
              if (_busy == i)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ask = widget.ask;
    final window = widget.window;
    if (_hidden) return const SizedBox.shrink();
    final enabled = _busy == null && widget.remote.online;
    // Picking presses keys in the agent's window: with none, only the screen and Hide.
    final picks = enabled && window != null;
    return Container(
      // Of what the keyboard leaves: the composer below stays on screen.
      constraints: BoxConstraints(
        maxHeight: (MediaQuery.sizeOf(context).height - MediaQuery.viewInsetsOf(context).bottom) * .55,
      ),
      decoration: const BoxDecoration(
        color: C.win,
        border: Border(top: BorderSide(color: C.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    ask.title.isEmpty
                        ? (widget.remote.session(widget.session)?.agent ?? widget.remote.agent).label
                        : ask.title,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                if (widget.onScreen case final screen?)
                  TextButton(key: const ValueKey('menu-screen'), onPressed: screen, child: const Text('Screen')),
                if (window != null)
                  TextButton(
                    key: const ValueKey('menu-cancel'),
                    onPressed: enabled ? () => unawaited(_do(-1, () => widget.remote.press(window, 'esc'))) : null,
                    child: _busy == -1
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Cancel'),
                  )
                else
                  TextButton(
                    key: const ValueKey('menu-hide'),
                    onPressed: () => setState(() => _hidden = true),
                    child: const Text('Hide'),
                  ),
              ],
            ),
          ),
          if (window == null)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                'PocketTerm can’t press keys in this terminal. Pick on the computer.',
                style: TextStyle(fontSize: 13, color: C.dim),
              ),
            ),
          if (ask.filter && window != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: TextField(
                key: const ValueKey('menu-search'),
                controller: _search,
                enabled: widget.remote.online,
                onTapOutside: dismissKeyboard,
                onChanged: _searchChanged,
                autocorrect: false,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search…',
                  hintStyle: const TextStyle(color: C.dim2),
                  prefixIcon: const Icon(Icons.search, size: 18, color: C.dim2),
                  isDense: true,
                  filled: true,
                  fillColor: C.field,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                ),
              ),
            ),
          Flexible(
            child: ask.items.isEmpty
                ? const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Text('Nothing matches.', style: TextStyle(fontSize: 13, color: C.dim)),
                  )
                : ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    children: [for (final (i, item) in ask.items.indexed) _item(i, item, enabled: picks)],
                  ),
          ),
        ],
      ),
    );
  }
}
