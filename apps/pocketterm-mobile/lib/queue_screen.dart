import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/terminal.dart' show TerminalException;
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';
import 'package:pocketterm_mobile/terminal_view.dart' show baseName;

/// A session's queue as the phone shows it: the computer's, with the moves and deletes made here ahead of it until
/// the computer's queue says the same.
class QueueView {
  /// The order set here (ids), until the computer's queue has it.
  List<String>? _order;

  /// Deleted or sent from here, until the computer's queue no longer has them.
  final gone = <String>{};

  /// The computer's [queue] in the order set here, and of those the ones that show.
  (List<LiveQueued>, List<LiveQueued>) items(List<LiveQueued> queue) {
    final ids = [for (final q in queue) q.id];
    gone.removeWhere((id) => !ids.contains(id));
    final order = _order;
    if (order != null && listEquals(ids.where(order.contains).toList(), order.where(ids.contains).toList())) {
      _order = null;
    }
    final byId = {for (final q in queue) q.id: q};
    final all = _order == null
        ? queue
        : [
            for (final id in _order!) ?byId[id],
            for (final q in queue)
              if (!_order!.contains(q.id)) q,
          ];
    return (
      all,
      [
        for (final q in all)
          if (!gone.contains(q.id)) q,
      ],
    );
  }

  /// Shows [id] at place [to] among [all] from now on; its place.
  int put(List<LiveQueued> all, String id, int to) {
    final order = [for (final q in all) q.id]
      ..remove(id)
      ..insert(to, id);
    _order = order;
    return to;
  }

  /// Shows the one shown at [from] at [to] (its place among [shown] once moved) from now on; its place among [all],
  /// those going too: before the one it now sits above, else after the one below.
  int drop(List<LiveQueued> all, List<LiveQueued> shown, int from, int to) {
    final id = shown[from].id;
    final seen = [for (final q in shown) q.id]
      ..removeAt(from)
      ..insert(to, id);
    final order = [for (final q in all) q.id]..remove(id);
    order.insert(to + 1 < seen.length ? order.indexOf(seen[to + 1]) : order.indexOf(seen[to - 1]) + 1, id);
    _order = order;
    return order.indexOf(id);
  }

  /// The computer's order again: a move it refused.
  void forgetOrder() => _order = null;
}

/// A session's name, as its page's title.
String sessionTitle(LiveSummary s) => s.title.isNotEmpty ? s.title : baseName(s.cwd);

/// Opens [session]'s queue over the whole screen.
Future<void> openQueue(BuildContext context, TerminalRemote remote, String session) => showFullscreenModal<void>(
  context,
  closeKey: const ValueKey('queue-close'),
  title: ListenableBuilder(
    listenable: remote,
    builder: (_, _) => Text(switch (remote.session(session)) {
      final s? => sessionTitle(s),
      null => 'Queue',
    }, key: const ValueKey('queue-title')),
  ),
  builder: (_) => QueueScreen(remote: remote, session: session),
);

/// Every prompt waiting in [session]'s queue on the computer, whole: each can be edited in place, moved (dragged, or
/// to the top or bottom), sent now (an agent that steers), copied or deleted; the queue paused or cleared, and a
/// prompt added at its end. Follows the computer: one that goes to the agent shows as Sent for a moment. Offline,
/// it only shows.
class QueueScreen extends StatefulWidget {
  const QueueScreen({required this.remote, required this.session, super.key});
  final TerminalRemote remote;
  final String session;

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

/// One that just left the queue for the agent, shown as Sent for a moment.
class _Sent {
  _Sent(this.item);
  final LiveQueued item;
  bool leaving = false;
}

class _QueueScreenState extends State<QueueScreen> {
  final _view = QueueView();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  bool _pausing = false;

  /// The one being edited in place, and its text.
  String? _editing;
  final _editField = TextEditingController();
  final GlobalKey _editorKey = GlobalKey();

  /// The keyboard's height last seen.
  double _keyboard = 0;

  /// Text saved here, by id, until the computer's queue has it.
  final _edited = <String, String>{};

  /// Long ones shown whole.
  final _open = <String>{};

  /// Deleted from here: they leave, but weren't sent.
  final _deleted = <String>{};

  /// Sent now from here.
  final _sentNow = <String>{};

  final _sent = <_Sent>[];
  final _timers = <Timer>[];
  late List<LiveQueued> _last;

  final _add = TextEditingController();
  bool _adding = false;

  /// How long one that went shows as Sent.
  static const _sentFor = Duration(milliseconds: 1500);

  /// Lines a long prompt shows until it's opened.
  static const _lines = 6;

  TerminalRemote get remote => widget.remote;
  LiveSummary? get _summary => remote.session(widget.session);

  @override
  void initState() {
    super.initState();
    _last = _summary?.queue ?? const [];
    remote.addListener(_changed);
    _editField.addListener(() => setState(() {}));
    _add.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    remote.removeListener(_changed);
    for (final t in _timers) {
      t.cancel();
    }
    _editField.dispose();
    _add.dispose();
    super.dispose();
  }

  /// The computer's queue changed: the next one leaving it from the front went to the agent (so did one sent now
  /// from here); one deleted here just goes.
  void _changed() {
    final queue = _summary?.queue ?? const <LiveQueued>[];
    final ids = {for (final q in queue) q.id};
    for (final (i, q) in _last.indexed) {
      if (ids.contains(q.id) || _deleted.contains(q.id)) continue;
      if (i == 0 || _sentNow.contains(q.id)) _showSent(q);
    }
    _deleted.removeWhere((id) => !ids.contains(id));
    _sentNow.removeWhere((id) => !ids.contains(id));
    final byId = {for (final q in queue) q.id: q};
    _edited.removeWhere((id, text) => byId[id] == null || byId[id]!.text == text);
    if (_editing != null && !ids.contains(_editing)) _editing = null;
    _last = queue;
    if (mounted) setState(() {});
  }

  void _showSent(LiveQueued q) {
    final sent = _Sent(q);
    _sent.add(sent);
    _timers
      ..add(
        Timer(_sentFor, () {
          if (mounted) setState(() => sent.leaving = true);
        }),
      )
      ..add(
        Timer(_sentFor + Motion.fast * 2, () {
          if (mounted) setState(() => _sent.remove(sent));
        }),
      );
  }

  void _say(String text, {SnackBarAction? action}) => _messenger.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(text),
        action: action,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(15, 5, 15, 10),
      ),
    );

  void _toast(Object e) => _say(e is TerminalException ? e.message : '$e');

  /// Takes [id] out of the list at once, back if [request] fails; whether it went.
  Future<bool> _drop(String id, Future<void> Function() request) async {
    setState(() => _view.gone.add(id));
    try {
      await request();
      return true;
    } on Object catch (e) {
      if (!mounted) return false;
      setState(() => _view.gone.remove(id));
      _toast(e);
      return false;
    }
  }

  Future<void> _move(String id, int to) async {
    try {
      await remote.moveQueued(widget.session, id, to);
    } on Object catch (e) {
      if (!mounted) return;
      setState(_view.forgetOrder);
      _toast(e);
    }
  }

  /// Whether [q] can go into the queue again from here (a copy, an undo): only its text can be sent again, it isn't
  /// a command (those are typed into the agent at once), and only a working agent queues it.
  bool _requeueable(LiveQueued q) {
    final s = _summary;
    final text = q.text.trim();
    return q.images == 0 &&
        q.files.isEmpty &&
        !q.cut &&
        text.isNotEmpty &&
        !text.startsWith('/') &&
        s != null &&
        (s.busy || s.ask != null);
  }

  /// Queues [text] again, at place [at]: a copy, or one deleted coming back.
  Future<void> _requeue(String text, int at) async {
    final s = _summary;
    if (s == null || !(s.busy || s.ask != null)) {
      return _say("The run has ended, so it can't wait in the queue. Send it from the chat.");
    }
    try {
      final id = await remote.prompt(widget.session, text, followUp: true);
      if (id == null) return _say('The run had ended: it went to the agent.');
      await remote.moveQueued(widget.session, id, at);
    } on Object catch (e) {
      if (mounted) _toast(e);
    }
  }

  /// Asks first when [q] can't come back: its images and files went to the computer once.
  Future<bool> _sureToDelete(LiveQueued q) async =>
      _requeueable(q) ||
      await confirmDanger(
        context,
        title: 'Delete this prompt?',
        body: 'It never goes to the agent, and it can’t be undone.',
        action: 'Delete',
      );

  Future<void> _delete(LiveQueued q, int at, {bool asked = false}) async {
    if (!asked && !await _sureToDelete(q)) return;
    final undo = _requeueable(q);
    _deleted.add(q.id);
    if (!await _drop(q.id, () => remote.removeQueued(widget.session, q.id)) || !mounted) {
      _deleted.remove(q.id);
      return;
    }
    if (undo) {
      _say(
        'Deleted',
        action: SnackBarAction(label: 'Undo', onPressed: () => unawaited(_requeue(q.text, at))),
      );
    }
  }

  Future<void> _clear(List<LiveQueued> shown) async {
    final n = shown.length;
    final sure = await confirmDanger(
      context,
      title: 'Clear the queue?',
      body: n == 1 ? 'The prompt never goes to the agent.' : 'All $n prompts are deleted; none of them go.',
      action: 'Clear all',
    );
    if (!sure || !mounted) return;
    _deleted.addAll([for (final q in shown) q.id]);
    await Future.wait([for (final q in shown) _drop(q.id, () => remote.removeQueued(widget.session, q.id))]);
  }

  Future<void> _pause({required bool paused}) async {
    setState(() => _pausing = true);
    try {
      await remote.pauseQueue(widget.session, paused: paused);
    } on Object catch (e) {
      if (mounted) _toast(e);
    }
    if (mounted) setState(() => _pausing = false);
  }

  void _startEdit(LiveQueued q) {
    setState(() {
      _editing = q.id;
      _editField.text = _edited[q.id] ?? q.text;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealEditor());
  }

  /// The keyboard came up or grew: the one being edited stays in view, Save and Cancel too, not just the line
  /// typed in.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    if (keyboard == _keyboard) return;
    _keyboard = keyboard;
    if (_editing != null) WidgetsBinding.instance.addPostFrameCallback((_) => _revealEditor());
  }

  void _revealEditor() {
    final c = _editorKey.currentContext;
    if (!mounted || c == null) return;
    Scrollable.ensureVisible(c, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
  }

  Future<void> _save(LiveQueued q) async {
    final text = _editField.text.trim();
    setState(() => _editing = null);
    if (text == (_edited[q.id] ?? q.text)) return;
    setState(() => _edited[q.id] = text);
    try {
      await remote.editQueued(widget.session, q.id, text);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _edited.remove(q.id));
      _toast(e);
    }
  }

  Future<void> _addPrompt() async {
    final text = _add.text.trim();
    if (text.isEmpty) return;
    if (text.startsWith('/')) return _say('Commands can’t wait in the queue. Send them from the chat.');
    setState(() => _adding = true);
    try {
      final id = await remote.prompt(widget.session, text, followUp: true);
      _add.clear();
      if (id == null) _say('The run had ended: it went to the agent.');
    } on Object catch (e) {
      if (mounted) _toast(e);
    }
    if (mounted) setState(() => _adding = false);
  }

  void _act(String what, LiveQueued q, List<LiveQueued> all) {
    final at = all.indexOf(q);
    switch (what) {
      case 'edit':
        _startEdit(q);
      case 'send':
        _sentNow.add(q.id);
        unawaited(_drop(q.id, () => remote.sendQueuedNow(widget.session, q.id)));
      case 'top':
        setState(() => _view.put(all, q.id, 0));
        unawaited(_move(q.id, 0));
      case 'bottom':
        setState(() => _view.put(all, q.id, all.length - 1));
        unawaited(_move(q.id, all.length - 1));
      case 'copy':
        unawaited(_requeue(q.text, at + 1));
      case 'delete':
        unawaited(_delete(q, at));
    }
  }

  @override
  Widget build(BuildContext context) => ScaffoldMessenger(
    key: _messenger,
    child: Scaffold(
      backgroundColor: Colors.transparent,
      // The sheet already keeps clear of the keyboard.
      resizeToAvoidBottomInset: false,
      body: _body(),
      // Toasts float above it.
      bottomNavigationBar: _addBar(_summary, online: remote.online && _summary != null),
    ),
  );

  Widget _body() {
    final s = _summary;
    final online = remote.online && s != null;
    final (all, shown) = _view.items(s?.queue ?? const []);
    final paused = s?.paused ?? false;
    final steers = s?.agent.steers ?? false;
    final (state, stateColor) = switch (s) {
      null => ('Ended', C.dim),
      _ when paused => ('Paused', C.warn),
      LiveSummary(busy: true) => ('Working', C.accent),
      LiveSummary(ask: _?) => ('Waiting for you', C.warn),
      _ => ('Idle', C.dim),
    };
    final note = switch ((s, remote.online)) {
      (null, _) => 'The session has ended.',
      (_, false) => 'Offline: you can look, but not change it.',
      _ when paused && !s!.busy => 'Nothing goes until you resume.',
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  children: [
                    Text(
                      '${C.label('Queued')} · ${shown.length}',
                      key: const ValueKey('queue-count'),
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: C.dim),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(color: stateColor, shape: BoxShape.circle),
                          child: const SizedBox(width: 7, height: 7),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          C.label(state),
                          key: const ValueKey('queue-state'),
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: stateColor),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (shown.isNotEmpty)
                IconButton(
                  key: const ValueKey('queue-clear'),
                  tooltip: 'Clear all',
                  onPressed: online ? () => unawaited(_clear(shown)) : null,
                  icon: Icon(Icons.delete_sweep_outlined, color: online ? C.error : C.dim2),
                ),
              if (shown.isNotEmpty || paused)
                TextButton(
                  key: ValueKey(paused ? 'queue-screen-resume' : 'queue-screen-pause'),
                  onPressed: online && !_pausing ? () => unawaited(_pause(paused: !paused)) : null,
                  child: Text(C.label(paused ? 'Resume' : 'Pause')),
                ),
            ],
          ),
        ),
        Reveal(
          visible: note != null,
          child: Padding(
            key: ValueKey(note),
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Row(
              children: [
                if (!remote.online) ...[Icon(Icons.cloud_off, size: 15, color: C.dim), const SizedBox(width: 6)],
                Expanded(
                  child: Text(note ?? '', style: TextStyle(fontSize: 12, color: C.dim)),
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: C.divider),
        Expanded(
          child: shown.isEmpty && _sent.isEmpty
              ? _empty()
              : ReorderableListView(
                  key: const ValueKey('queue-list'),
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.only(bottom: 12),
                  header: Column(children: [for (final sent in _sent) _sentRow(sent)]),
                  onReorderItem: (from, to) {
                    if (from == to) return;
                    final id = shown[from].id;
                    final at = _view.drop(all, shown, from, to);
                    setState(() {});
                    unawaited(_move(id, at));
                  },
                  children: [
                    for (final (i, q) in shown.indexed)
                      _row(q, i, all, online: online, steers: steers, last: i == shown.length - 1),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _empty() => Center(
    key: const ValueKey('queue-empty'),
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 40, color: C.dim2),
          const SizedBox(height: 12),
          Text(
            'Nothing queued',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: C.text),
          ),
          const SizedBox(height: 4),
          Text(
            'Prompts you queue while the agent works wait here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: C.dim),
          ),
        ],
      ),
    ),
  );

  Widget _sentRow(_Sent sent) => Reveal(
    visible: !sent.leaving,
    child: Padding(
      key: ValueKey('queue-sent-${sent.item.id}'),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Row(
        children: [
          Icon(Icons.check, size: 16, color: C.ok),
          const SizedBox(width: 8),
          Text(
            C.label('Sent'),
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: C.ok),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              sent.item.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: C.dim),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _row(
    LiveQueued q,
    int index,
    List<LiveQueued> all, {
    required bool online,
    required bool steers,
    required bool last,
  }) {
    final editing = _editing == q.id;
    final extras = [if (q.images > 0) '⊕ ${q.images} image${q.images == 1 ? '' : 's'}', ...q.files];
    final at = all.indexOf(q);
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: C.dim,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (editing) _editor(q) else _text(q),
                if (extras.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(extras.join(' · '), style: TextStyle(fontSize: 12, color: C.dim)),
                  ),
                if (q.cut)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Too long to show whole here.', style: TextStyle(fontSize: 12, color: C.dim2)),
                  ),
              ],
            ),
          ),
          if (!editing) ...[
            Semantics(
              identifier: 'queue-menu-${q.id}',
              child: PopupMenuButton<String>(
                key: ValueKey('queue-menu-${q.id}'),
                tooltip: 'More',
                enabled: online,
                icon: Icon(Icons.more_vert, size: 20, color: online ? C.dim : C.dim2),
                color: C.card,
                onSelected: (what) => _act(what, q, all),
                itemBuilder: (_) => [
                  if (!q.cut) const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  if (steers) const PopupMenuItem(value: 'send', child: Text('Send now')),
                  if (at > 0) const PopupMenuItem(value: 'top', child: Text('Move to top')),
                  if (at < all.length - 1) const PopupMenuItem(value: 'bottom', child: Text('Move to bottom')),
                  if (_requeueable(q)) const PopupMenuItem(value: 'copy', child: Text('Duplicate')),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete', style: TextStyle(color: C.error)),
                  ),
                ],
              ),
            ),
            ReorderableDragStartListener(
              index: index,
              enabled: online,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
                child: Icon(Icons.drag_handle, size: 20, color: online ? C.dim : C.dim2),
              ),
            ),
          ],
        ],
      ),
    );
    return Dismissible(
      key: ValueKey('queue-item-${q.id}'),
      direction: online && !editing ? DismissDirection.endToStart : DismissDirection.none,
      background: Container(
        color: C.error.withValues(alpha: .15),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Icon(Icons.delete_outline, color: C.error),
      ),
      confirmDismiss: (_) => _sureToDelete(q),
      onDismissed: (_) => unawaited(_delete(q, at, asked: true)),
      child: ReorderableDelayedDragStartListener(
        index: index,
        enabled: online && !editing,
        child: Material(
          color: editing ? C.field : C.card,
          child: InkWell(
            onTap: online && !editing && !q.cut ? () => _startEdit(q) : null,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: last ? null : Border(bottom: BorderSide(color: C.divider, width: .5)),
              ),
              child: row,
            ),
          ),
        ),
      ),
    );
  }

  /// [q]'s text, whole once opened when it's long.
  Widget _text(LiveQueued q) {
    final text = _edited[q.id] ?? q.text;
    if (text.isEmpty) {
      return Text(
        '(no text)',
        style: TextStyle(fontSize: 15, color: C.dim, fontStyle: FontStyle.italic),
      );
    }
    final style = TextStyle(fontSize: 15, color: C.text, height: 1.35);
    return LayoutBuilder(
      builder: (context, box) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: _lines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: box.maxWidth);
        final long = painter.didExceedMaxLines;
        painter.dispose();
        final open = _open.contains(q.id);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              key: ValueKey('queue-text-${q.id}'),
              maxLines: long && !open ? _lines : null,
              overflow: long && !open ? TextOverflow.ellipsis : null,
              style: style,
            ),
            if (long)
              GestureDetector(
                key: ValueKey('queue-more-${q.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => open ? _open.remove(q.id) : _open.add(q.id)),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 2),
                  child: Text(
                    open ? 'Show less' : 'Show more',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: C.accent),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _editor(LiveQueued q) {
    final text = _editField.text.trim();
    final canSave = text.isNotEmpty || q.images > 0 || q.files.isNotEmpty;
    return Column(
      key: _editorKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('queue-edit-field'),
          controller: _editField,
          autofocus: true,
          minLines: 2,
          maxLines: 12,
          textCapitalization: TextCapitalization.sentences,
          style: TextStyle(fontSize: 15, height: 1.35, color: C.text),
          decoration: setupField('Prompt'),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              key: const ValueKey('queue-edit-cancel'),
              onPressed: () => setState(() => _editing = null),
              child: Text('Cancel', style: TextStyle(color: C.text)),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('queue-edit-save'),
              onPressed: canSave ? () => unawaited(_save(q)) : null,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }

  /// A prompt to add at the end of the queue: only while the agent works, else it would go at once.
  Widget _addBar(LiveSummary? s, {required bool online}) {
    final open = online && s != null && (s.busy || s.ask != null);
    final ready = open && !_adding && _add.text.trim().isNotEmpty;
    return DecoratedBox(
      decoration: BoxDecoration(
        // The sheet's own surface, which runs on under the home indicator.
        color: C.card,
        border: Border(
          top: BorderSide(color: C.divider, width: C.border),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('queue-add-field'),
                controller: _add,
                enabled: open && !_adding,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                onTapOutside: dismissKeyboard,
                style: TextStyle(fontSize: 15, color: C.text),
                decoration: setupField(open ? 'Add to the queue' : 'Adds while the agent works'),
              ),
            ),
            const SizedBox(width: 4),
            Semantics(
              identifier: 'queue-add',
              child: IconButton(
                key: const ValueKey('queue-add'),
                tooltip: 'Add',
                onPressed: ready ? () => unawaited(_addPrompt()) : null,
                icon: Icon(Icons.arrow_upward_rounded, color: ready ? C.accent : C.dim2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
