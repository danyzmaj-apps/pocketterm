import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/ansi.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/native.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';
import 'package:pocketterm_mobile/coach.dart';
import 'package:pocketterm_mobile/session_view.dart';
import 'package:pocketterm_mobile/swipe_action.dart';
import 'package:pocketterm_mobile/switch_view.dart';

// Line height 1.2: box-drawing characters still nearly join up.
const _mono = TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['Courier'], fontSize: 11, height: 1.2);
const _monoStrut = StrutStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['Courier'],
  fontSize: 11,
  height: 1.2,
  forceStrutHeight: true,
);
const double _lineHeight = 11 * 1.2;

/// Shows what went wrong at the bottom of the screen, clear of [above] (a
/// page's composer).
void termToast(BuildContext context, Object e, {GlobalKey? above}) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(
    SnackBar(
      content: Text(e is TerminalException ? e.message : '$e'),
      behavior: SnackBarBehavior.floating,
      margin: toastMargin(above),
    ),
  );

/// `/Users/me/Dev/x` as `~/Dev/x` (`C:\Users\me\x` as `~\x`).
String shortPath(TerminalRemote r, String path) =>
    r.home.isNotEmpty && path.startsWith(r.home) ? '~${path.substring(r.home.length)}' : path;

/// A folder's last part: the project. A Windows computer's paths take `\`.
String baseName(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

final _drive = RegExp(r'^[A-Za-z]:[\\/]');

/// A folder typed in as the computer's path: `~/x` (from [home]), `/x`, or
/// `C:\x` on a Windows computer; null for anything else (a search).
String? typedPath(String typed, String home) {
  final q = typed.trim();
  if (q.startsWith('~')) {
    final rest = q.substring(1);
    return '$home${_drive.hasMatch(home) ? rest.replaceAll('/', r'\') : rest}';
  }
  return q.startsWith('/') || _drive.hasMatch(q) ? q : null;
}

/// How long ago [t] was: "just now", "5 min ago", "3 h ago", "2 d ago".
String ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// How people name a window's terminal app ([TermWindow.app]).
String termLabel(String app) => switch (app) {
  'kitty' => 'kitty',
  'tmux' => 'tmux',
  'wezterm' => 'WezTerm',
  'ghostty' => 'Ghostty',
  _ => app,
};

/// Which terminal [w] is in: "WezTerm", or "tmux · Ghostty" for a tmux pane
/// shown in Ghostty.
String termBadge(TermWindow w) => w.app == 'tmux' && w.via.isNotEmpty ? 'tmux · ${w.via}' : termLabel(w.app);

/// A small rounded label on a list row: a window's terminal ([termBadge]), or that it shows only as a screen.
class TermBadge extends StatelessWidget {
  const TermBadge(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: const Color(0xFF262833),
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: C.line2),
    ),
    child: Text(text, style: const TextStyle(fontSize: 11, color: C.dim, height: 1.3)),
  );
}

/// A list row's line after [w]'s badge, when the window is known; [screenOnly]: a coding agent's window no live
/// session claims, badged so.
Widget _badged(TermWindow? w, Widget line, {bool screenOnly = false}) => w == null
    ? line
    : Row(
        children: [
          TermBadge(termBadge(w)),
          const SizedBox(width: 6),
          if (screenOnly) ...[
            TermBadge('Screen only', key: ValueKey('screen-only-${w.key}')),
            const SizedBox(width: 6),
          ],
          Expanded(child: line),
        ],
      );

/// Closes [w] on the computer (callers ask first: [CloseConfirm], or a row's
/// [SwipeAction]); true once it's closed.
Future<bool> closeWindow(BuildContext context, TerminalRemote remote, TermWindow w) async {
  try {
    await remote.close(w.key);
    return true;
  } on Object catch (e) {
    if (context.mounted) termToast(context, e);
    return false;
  }
}

/// Asks in place, before [window] closes: its agent's session ends (or the
/// window closes) on the computer, and what runs in it with it. It slides in
/// as it shows. [closing]: the close went, and the computer hasn't answered.
class CloseConfirm extends StatelessWidget {
  const CloseConfirm({
    required this.remote,
    required this.window,
    required this.onCancel,
    required this.onClose,
    this.closing = false,
    super.key,
  });
  final TerminalRemote remote;
  final TermWindow window;
  final VoidCallback onCancel;
  final VoidCallback onClose;
  final bool closing;

  @override
  Widget build(BuildContext context) {
    final agent = window.agent;
    final who = remote.desktopName ?? 'the computer';
    final where = window.cwd.isEmpty ? '' : ' in ${shortPath(remote, window.cwd)}';
    final (title, detail, action) = agent != null
        ? ('End this ${agent.label} session on $who?', 'Its window$where closes with it.', 'End session')
        : (
            'Close this window on $who?',
            '${window.program.isEmpty ? 'Whatever runs in it' : window.program}$where stops with it.',
            'Close window',
          );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.fast,
      curve: Motion.ease,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 12 * (1 - t)), child: child),
      ),
      child: Container(
        key: ValueKey('confirm-close-${window.key}'),
        color: const Color(0x557F1D1D),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
            const SizedBox(height: 2),
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: C.dim, height: 1.3),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('close-cancel'),
                  onPressed: closing ? null : onCancel,
                  child: Text('Keep', style: TextStyle(color: closing ? C.dim2 : C.text)),
                ),
                const SizedBox(width: 8),
                if (closing)
                  const SizedBox(
                    key: ValueKey('close-sent'),
                    width: 48,
                    height: 40,
                    child: Center(
                      child: SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: swipeActionText),
                      ),
                    ),
                  )
                else
                  FilledButton(
                    key: const ValueKey('close-confirm'),
                    style: FilledButton.styleFrom(backgroundColor: swipeActionColor, foregroundColor: swipeActionText),
                    onPressed: onClose,
                    child: Text(action),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What's wrong with the link, if anything, as one line for the top of a
/// screen (on [color]: a bar by default); with how old the shown state is when
/// it isn't live. Keyed by its text, so a [Reveal] cross-fades a change.
Widget? linkNote(TerminalRemote r, {Color color = C.bar}) {
  final at = r.stateAt;
  final who = r.desktopName ?? 'the computer';
  final (text, busy) = switch (r.link) {
    TerminalLink.connecting => ('connecting…', true),
    TerminalLink.waiting => ('asking $who…', true),
    TerminalLink.offline => (
      "$who isn't answering. It has to be awake, with PocketTerm running and "
          'Settings → Terminal from phone on.',
      false,
    ),
    TerminalLink.online => (r.error, false),
  };
  if (text == null) return null;
  final line = r.link == TerminalLink.online
      ? text
      : at != null
      ? 'Updated ${ago(at)} · $text'
      : '${text[0].toUpperCase()}${text.substring(1)}';
  return Container(
    key: ValueKey('link-note-$line'),
    color: color,
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
    child: Row(
      children: [
        if (busy) ...[
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(line, style: const TextStyle(fontSize: 13, color: C.dim, height: 1.4)),
        ),
      ],
    ),
  );
}

/// Opens coding session [key]; [starting]: it was just launched and its agent
/// may not have reported yet.
void openSession(BuildContext context, TerminalRemote remote, String key, {bool starting = false}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionPage(remote: remote, sessionKey: key, starting: starting),
      ),
    );

/// Opens terminal window [window]'s screen.
void openWindow(BuildContext context, TerminalRemote remote, String window) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => TerminalPage(remote: remote, window: window),
  ),
);

/// Asks where to start a session, starts it and opens it.
Future<void> openNewSession(BuildContext context, TerminalRemote remote) async {
  final launched = await showAppSheet<({String window, bool agent})>(
    context,
    isScrollControlled: true,
    builder: (_) => NewSessionSheet(remote: remote),
  );
  if (launched == null || !context.mounted) return;
  if (launched.agent) {
    // An agent the phone started: its session's key is its window's.
    openSession(context, remote, launched.window, starting: true);
  } else {
    openWindow(context, remote, launched.window);
  }
}

/// The sessions in one project folder.
typedef SessionGroup = ({String cwd, List<LiveSummary> sessions});

/// How the Terminal list orders its projects.
enum ProjectSort {
  /// A–Z by folder name; somewhere unknown last.
  name,

  /// Most recent activity first, as last ranked (see [groupedSessions]).
  activity,
}

/// Sessions by project folder, each project's in the computer's order (as it
/// first saw them), so a session changing state never moves.
///
/// [sort] orders the projects. By activity, the projects in [ranked] keep its
/// order, so the list doesn't reshuffle while it's looked at; projects not
/// in it yet go first, the most recently active first. An empty [ranked]
/// ranks them all afresh.
List<SessionGroup> groupedSessions(List<LiveSummary> sessions, ProjectSort sort, {List<String> ranked = const []}) {
  final byCwd = <String, List<LiveSummary>>{};
  for (final s in sessions) {
    (byCwd[s.cwd] ??= []).add(s);
  }
  final List<String> order;
  switch (sort) {
    case ProjectSort.name:
      String name(String cwd) => baseName(cwd).toLowerCase();
      order = byCwd.keys.toList()
        ..sort((a, b) {
          if (a.isEmpty != b.isEmpty) return a.isEmpty ? 1 : -1;
          final r = name(a).compareTo(name(b));
          return r != 0 ? r : a.compareTo(b);
        });
    case ProjectSort.activity:
      final epoch = DateTime.fromMillisecondsSinceEpoch(0);
      DateTime latest(String cwd) => byCwd[cwd]!.map((s) => s.at ?? epoch).reduce((a, b) => a.isAfter(b) ? a : b);
      final known = {...ranked};
      order = [
        ...byCwd.keys.where((c) => !known.contains(c)).toList()..sort((a, b) => latest(b).compareTo(latest(a))),
        ...ranked.where(byCwd.containsKey),
      ];
  }
  return [for (final cwd in order) (cwd: cwd, sessions: byCwd[cwd]!)];
}

/// "Needs you", "Working…" or how long it has been idle.
String sessionState(LiveSummary s) => s.ask != null
    ? 'Needs you'
    : s.busy
    ? 'Working…'
    : (s.at == null ? 'Idle' : ago(s.at!));

Color sessionColor(LiveSummary s) => s.ask != null ? C.warn : (s.busy ? C.accent : C.dim2);

/// The home page's body: the computer's coding sessions by project, in a
/// steady order, and its other terminal windows. Tapping a project's heading
/// folds it; long-pressing it offers a new session there and folding.
class TerminalList extends StatefulWidget {
  const TerminalList({
    required this.remote,
    required this.folded,
    required this.onFolded,
    required this.sort,
    required this.onSort,
    this.computer,
    super.key,
  });
  final TerminalRemote remote;

  /// Projects (folders) showing only their heading and a summary, as kept;
  /// [onFolded] keeps them when they change.
  final Set<String> folded;
  final ValueChanged<Set<String>> onFolded;

  /// How projects are ordered, as kept; [onSort] keeps a new choice.
  final ProjectSort sort;
  final ValueChanged<ProjectSort> onSort;

  /// The computer's name, for advice about it; null says "the computer".
  final String? computer;

  @override
  State<TerminalList> createState() => _TerminalListState();
}

class _TerminalListState extends State<TerminalList> {
  TerminalRemote get remote => widget.remote;

  late final Set<String> _folded = {...widget.folded};
  late ProjectSort _sort = widget.sort;

  /// By activity: the projects' order as last shown, kept until the list
  /// is pulled to refresh or the sort changes.
  List<String> _ranked = const [];

  /// The project a new session is starting in.
  String? _launching;

  /// The window whose row is swiped open, its End session or Close window
  /// showing; it shuts again after a while untouched.
  String? _open;
  Timer? _openTimer;

  /// The windows a close went for, until the computer answers: they can't be
  /// closed again meanwhile.
  final _closing = <String>{};

  /// The rows showing [Tip.switchOpen] and [Tip.swipeRow], as last built.
  String? _switchTipRow;
  String? _swipeTipRow;

  @override
  void dispose() {
    _openTimer?.cancel();
    super.dispose();
  }

  void _setFolded(Set<String> folded) {
    setState(
      () => _folded
        ..clear()
        ..addAll(folded),
    );
    widget.onFolded({..._folded});
  }

  void _fold(String cwd) => _setFolded(_folded.contains(cwd) ? (_folded.toSet()..remove(cwd)) : {..._folded, cwd});

  void _setSort(ProjectSort sort) {
    if (sort == _sort) return;
    setState(() {
      _sort = sort;
      _ranked = const [];
    });
    widget.onSort(sort);
  }

  /// Starts the agent in a new window in [cwd], and opens its session.
  Future<void> _launchHere(String cwd) async {
    if (_launching != null) return;
    setState(() => _launching = cwd);
    // The app's navigator, which outlives this list if it's left meanwhile:
    // the session still opens, or what went wrong still shows.
    final nav = Navigator.of(context);
    try {
      final window = await remote.launch(cwd, startAgent: true);
      // An agent the phone started: its session's key is its window's.
      if (nav.mounted) openSession(nav.context, remote, window, starting: true);
    } on Object catch (e) {
      if (nav.mounted) termToast(nav.context, e);
    } finally {
      if (mounted) setState(() => _launching = null);
    }
  }

  /// [window]'s row opened ([open]) or shut; one row is open at a time.
  void _setOpen(String window, bool open) {
    if (!mounted || (!open && _open != window)) return;
    _openTimer?.cancel();
    if (open) _openTimer = Timer(const Duration(seconds: 5), () => _setOpen(window, false));
    setState(() => _open = open ? window : null);
  }

  /// A finger started on [window]'s row: any other open one shuts, and this
  /// one waits for it.
  void _swiping(String window) {
    _openTimer?.cancel();
    if (_open != null && _open != window) setState(() => _open = null);
  }

  Future<void> _close(TermWindow w) async {
    _openTimer?.cancel();
    setState(() => _closing.add(w.key));
    await closeWindow(context, remote, w);
    if (!mounted) return;
    setState(() {
      _closing.remove(w.key);
      if (_open == w.key) _open = null;
    });
  }

  /// [child], showing End session (Close window, for no agent) when swiped
  /// left; tapped, [w] closes at once.
  Widget _swipe(String key, TermWindow? w, Widget child) {
    if (w == null || !w.can(TermCap.close)) return child;
    final online = remote.online;
    final busy = _closing.contains(w.key);
    final row = SwipeAction(
      key: ValueKey('swipe-$key'),
      actionKey: ValueKey('swipe-action-$key'),
      open: busy || (online && _open == w.key),
      enabled: online,
      busy: busy,
      label: w.agent != null ? 'End session' : 'Close window',
      onSwipe: () => _swiping(w.key),
      onOpen: (open) => _setOpen(w.key, open),
      onAction: () => unawaited(_close(w)),
      child: child,
    );
    return key == _swipeTipRow ? _tipped(Tip.swipeRow, row) : row;
  }

  /// A session's row; its project is the heading above it.
  Widget _session(LiveSummary s) {
    final title = s.title.isNotEmpty ? s.title : s.agent.label;
    final w = s.window == null ? null : remote.window(s.window!);
    return _swipe(
      s.key,
      w,
      _tipped(
        s.window != null && s.window == Coach.maybeOf(context)?.switchedWindow ? Tip.switchDone : null,
        ListTile(
          key: ValueKey('session-${s.key}'),
          contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          onTap: () => openSession(context, remote, s.key),
          leading: Icon(Icons.auto_awesome, size: 18, color: sessionColor(s)),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _badged(
                w,
                Text(
                  sessionState(s),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: s.ask != null || s.busy ? sessionColor(s) : C.dim),
                ),
              ),
              if (s.preview.isNotEmpty)
                Text(
                  s.preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: C.dim2),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// [row] with [tip], if it has one; the cutout rounds like the card it sits in.
  static Widget _tipped(Tip? tip, Widget row) =>
      tip == null ? row : CoachTarget(tip: tip, radius: Panel.radius, padding: 0, child: row);

  /// A project's sessions under its name. Tapping the name folds it to one
  /// summary row; long-pressing it opens [_projectMenu].
  Widget _project(SessionGroup g, int projects, {required bool first}) {
    final folded = _folded.contains(g.cwd);
    return Panel(
      key: ValueKey('project-${g.cwd}'),
      title: _projectName(g.cwd).toUpperCase(),
      titleTip: first ? Tip.projectHeading : null,
      onTitleTap: () => _fold(g.cwd),
      onTitleLongPress: () {
        unawaited(HapticFeedback.selectionClick());
        unawaited(_projectMenu(g.cwd, projects));
      },
      titleTrailing: _launching == g.cwd
          ? SizedBox.square(
              key: ValueKey('project-launching-${g.cwd}'),
              dimension: 14,
              child: const CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      children: folded ? [_summary(g)] : [for (final s in g.sessions) _session(s)],
    );
  }

  static String _projectName(String cwd) => cwd.isEmpty ? 'Somewhere' : baseName(cwd);

  /// A folded project's one row: how many sessions, and what needs you or
  /// is working, so folding never hides a question.
  Widget _summary(SessionGroup g) {
    final n = g.sessions.length;
    final asking = g.sessions.where((s) => s.ask != null).length;
    final working = g.sessions.where((s) => s.busy && s.ask == null).length;
    final color = asking > 0 ? C.warn : (working > 0 ? C.accent : C.dim2);
    return ListTile(
      key: ValueKey('project-summary-${g.cwd}'),
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      onTap: () => _fold(g.cwd),
      leading: Icon(Icons.auto_awesome, size: 18, color: color),
      title: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$n session${n == 1 ? '' : 's'}'),
            if (asking > 0)
              TextSpan(
                text: ' · ${asking == 1 ? '1 needs' : '$asking need'} you',
                style: const TextStyle(color: C.warn),
              ),
            if (working > 0)
              TextSpan(
                text: ' · $working working',
                style: const TextStyle(color: C.accent),
              ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, color: C.dim),
      ),
    );
  }

  /// What a long press on a project's name offers: a new session there,
  /// folding it, and folding the others.
  Future<void> _projectMenu(String cwd, int projects) => showAppSheet<void>(
    context,
    builder: (sheet) {
      final folded = _folded.contains(cwd);
      final others = projects > 1;
      void run(VoidCallback action) {
        Navigator.of(sheet).pop();
        action();
      }

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, sheetTop, 20, 2),
              child: Text(_projectName(cwd), style: sheetTitleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (cwd.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  shortPath(remote, cwd),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: C.dim),
                ),
              ),
            // Somewhere unknown has nowhere to start one.
            if (cwd.isNotEmpty)
              ListTile(
                key: const ValueKey('project-menu-new'),
                leading: Icon(isIos ? Icons.add_rounded : Icons.add, color: C.accent),
                title: Text('New ${remote.agent.label} session here'),
                enabled: remote.online && _launching == null,
                onTap: () => run(() => unawaited(_launchHere(cwd))),
              ),
            ListTile(
              key: const ValueKey('project-menu-fold'),
              leading: Icon(folded ? Icons.unfold_more : Icons.unfold_less, color: C.dim),
              title: Text(folded ? 'Unfold' : 'Fold'),
              onTap: () => run(() => _fold(cwd)),
            ),
            if (others)
              ListTile(
                key: const ValueKey('project-menu-fold-others'),
                leading: const Icon(Icons.vertical_align_center, color: C.dim),
                title: const Text('Fold all others'),
                onTap: () => run(() {
                  final all = {for (final s in remote.sessions) s.cwd};
                  _setFolded({..._folded, ...all}..remove(cwd));
                }),
              ),
            if (others && _folded.isNotEmpty)
              ListTile(
                key: const ValueKey('project-menu-unfold-all'),
                leading: const Icon(Icons.unfold_more_double, color: C.dim),
                title: const Text('Unfold all'),
                onTap: () => run(() => _setFolded({})),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );

  /// Above the projects: how they're ordered, one tap to change it. Its
  /// press shows as a rounded pill around it, ending where the headings'
  /// trailing edge does.
  Widget _sortControl() => Align(
    alignment: Alignment.centerRight,
    child: Padding(
      padding: const EdgeInsets.only(right: 16),
      child: PopupMenuButton<ProjectSort>(
        key: const ValueKey('project-sort'),
        tooltip: 'Sort projects',
        initialValue: _sort,
        onSelected: _setSort,
        borderRadius: BorderRadius.circular(Panel.headingRadius),
        itemBuilder: (_) => [for (final s in ProjectSort.values) PopupMenuItem(value: s, child: Text(_sortLabel(s)))],
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_sortLabel(_sort), style: const TextStyle(fontSize: 13, color: C.dim)),
                const SizedBox(width: 2),
                const Icon(Icons.arrow_drop_down, size: 18, color: C.dim),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  static String _sortLabel(ProjectSort s) => switch (s) {
    ProjectSort.name => 'Name',
    ProjectSort.activity => 'Recent activity',
  };

  Widget _window(TermWindow w) => _swipe(
    w.key,
    w,
    _tipped(
      w.key == _switchTipRow ? Tip.switchOpen : null,
      ListTile(
        key: ValueKey('term-${w.key}'),
        contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        onTap: () => openWindow(context, remote, w.key),
        leading: Icon(
          w.agent != null ? Icons.auto_awesome : Icons.terminal,
          size: 18,
          color: w.focused ? C.accent : C.dim2,
        ),
        title: Text(
          w.title.isEmpty ? w.program : w.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        subtitle: _badged(
          w,
          Text(
            '${w.program} · ${shortPath(remote, w.cwd)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: C.dim),
          ),
          // The rows here are the windows no live session claims.
          screenOnly: w.agent != null,
        ),
      ),
    ),
  );

  /// Nothing runs: where a new session opens, and what each terminal that
  /// isn't ready needs (tmux: when it isn't installed).
  Widget _empty() {
    final online = remote.online;
    final unready = [
      for (final t in remote.terminals)
        if (t.state != TermState.ready && (t.state != TermState.missing || t.id == 'tmux')) t,
    ];
    final hint = online && remote.error == null;
    if (!hint && !(online && unready.isNotEmpty)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        children: [
          if (hint)
            Text(
              'Nothing runs in ${remote.opensIn ?? 'your terminal'}. Tap + to start ${remote.agent.label}.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: C.dim, height: 1.5),
            ),
          if (online)
            for (final (i, t) in unready.indexed)
              Padding(
                key: ValueKey('terminal-${t.id}'),
                padding: EdgeInsets.only(top: hint || i > 0 ? 12 : 0),
                child: Text(
                  '${t.label}: ${t.note.isNotEmpty ? t.note : _stateWord(t.state)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: C.dim2, height: 1.4),
                ),
              ),
        ],
      ),
    );
  }

  static String _stateWord(TermState s) => switch (s) {
    TermState.ready => 'ready',
    TermState.limited => 'limited',
    TermState.setup => 'needs setup on the computer',
    TermState.idle => 'not running',
    TermState.missing => 'not installed',
  };

  @override
  Widget build(BuildContext context) => _KeepAwake(child: _list());

  Widget _list() => ListenableBuilder(
    listenable: remote,
    builder: (context, _) {
      final note = linkNote(remote, color: Colors.transparent);
      final groups = groupedSessions(remote.sessions, _sort, ranked: _ranked);
      // What's shown is what stays: a project's activity reorders it only
      // on the next refresh.
      if (_sort == ProjectSort.activity) _ranked = [for (final g in groups) g.cwd];
      final claimed = {for (final s in remote.sessions) ?s.window};
      final windows = remote.windows.where((w) => !claimed.contains(w.key)).toList();
      // Agent windows the phone can switch to the conversation view; the others say why they show as screens.
      final switchable = windows.where((w) => canSwitch(remote, w)).length;
      // The rows that carry the switch tour's first tip and the swipe tip: the first that can.
      _switchTipRow = windows.where((w) => canSwitch(remote, w)).firstOrNull?.key;
      bool closes(String? window) => window != null && (remote.window(window)?.can(TermCap.close) ?? false);
      _swipeTipRow = [
        for (final g in groups)
          if (!_folded.contains(g.cwd))
            for (final s in g.sessions)
              if (closes(s.window)) s.key,
        for (final w in windows)
          if (closes(w.key)) w.key,
      ].firstOrNull;
      // The sessions and windows, in each platform's grouped cards.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Reveal(
            visible: note != null,
            child: Panel(key: note?.key, children: [?note]),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                setState(() => _ranked = const []);
                remote.hello();
                await Future<void>.delayed(const Duration(milliseconds: 600));
              },
              child: ListView(
                // Rows scroll on under the home indicator; the last one still comes up clear of the +.
                padding: EdgeInsets.only(bottom: AddButton.contentInset + MediaQuery.paddingOf(context).bottom),
                children: [
                  if (groups.isEmpty && windows.isEmpty) _empty(),
                  if (groups.length > 1) _sortControl(),
                  for (final (i, g) in groups.indexed) _project(g, groups.length, first: i == 0),
                  if (windows.isNotEmpty) ...[
                    Panel(
                      key: const ValueKey('windows-heading'),
                      title: groups.isEmpty ? 'WINDOWS' : 'OTHER WINDOWS',
                      children: const [],
                    ),
                    if (switchable > 0)
                      Padding(
                        key: const ValueKey('switch-tip'),
                        padding: const EdgeInsets.fromLTRB(32, 0, 24, 8),
                        child: Text(
                          switchable == 1
                              ? '1 session shows only its screen. Tap it to switch it to the conversation view.'
                              : '$switchable sessions show only their screen. Tap one to switch it to the '
                                    'conversation view.',
                          style: const TextStyle(fontSize: 12, color: C.dim2, height: 1.4),
                        ),
                      ),
                    // An agent whose PocketTerm integration doesn't report: out of date, or installed after it
                    // started in a window the phone can't switch.
                    for (final agent in Agent.values)
                      if (windows.any((w) => w.agent == agent && !canSwitch(remote, w)))
                        Padding(
                          key: ValueKey('${agent.command}-screens-only'),
                          padding: const EdgeInsets.fromLTRB(32, 0, 24, 8),
                          child: Text(
                            _screensOnly(agent, remote.agents[agent], widget.computer ?? 'the computer'),
                            style: const TextStyle(fontSize: 12, color: C.dim2, height: 1.4),
                          ),
                        ),
                    Panel(key: const ValueKey('windows'), children: [for (final w in windows) _window(w)]),
                  ],
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Why [agent]'s windows show only as screens, from where PocketTerm stands in it ([integration], null from a
/// computer that doesn't say) on [computer].
String _screensOnly(Agent agent, AgentIntegration? integration, String computer) {
  final (name, app, command) = switch (agent) {
    Agent.omp => ('omp', 'omp', 'omp'),
    Agent.claude => ('Claude', 'Claude Code', 'claude'),
  };
  // What loads it in a session that's already open: Claude Code reloads in place, omp restarts on the conversation.
  final pickUp = switch (agent) {
    Agent.omp => 'restart omp there (${agent.resume} keeps the conversation)',
    Agent.claude => 'type ${agent.pickUp} in these sessions (nothing restarts)',
  };
  return switch (integration) {
    AgentIntegration.missing =>
      'PocketTerm isn’t installed in $app on $computer. On the computer: PocketTerm Settings → Install, then '
          '$pickUp.',
    AgentIntegration.installed => switch (agent) {
      Agent.omp =>
        'These omp sessions started before PocketTerm was installed in omp. Quit omp in them and run '
            '${agent.resume} to see them here as conversations.',
      Agent.claude =>
        'These Claude sessions started before PocketTerm was installed in Claude Code. Type ${agent.pickUp} '
            'in them (nothing restarts) to see them here as conversations.',
    },
    AgentIntegration.outdated =>
      'PocketTerm in $app is out of date on $computer. On the computer: PocketTerm Settings → Update, then '
          '$pickUp.',
    AgentIntegration.off =>
      '$app on $computer has mods turned off, so PocketTerm’s ${agent == Agent.omp ? 'extension' : 'plugin'} doesn’t '
          'run. There: run $command /login, start $command once, then $pickUp.',
    null =>
      'These $name windows show only as screens: PocketTerm’s $app ${agent == Agent.omp ? 'extension' : 'plugin'} '
          'isn’t reporting from them. It may be out of date (update it in PocketTerm’s Settings on the computer), '
          'or $name there started before it was installed. Then $pickUp to see it above, as a conversation.',
  };
}

/// The screen stays on while the Terminal list is up (and the session and
/// screen pages pushed over it): a terminal is something you watch.
class _KeepAwake extends StatefulWidget {
  const _KeepAwake({required this.child});
  final Widget child;

  @override
  State<_KeepAwake> createState() => _KeepAwakeState();
}

class _KeepAwakeState extends State<_KeepAwake> {
  @override
  void initState() {
    super.initState();
    unawaited(Native.setKeepAwake(on: true));
  }

  @override
  void dispose() {
    unawaited(Native.setKeepAwake(on: false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// One terminal window: its screen as text, live, plus a composer and the
/// keys a terminal program needs (a coding agent's menus: arrows, Enter, Esc),
/// each as far as the window's terminal allows.
class TerminalPage extends StatefulWidget {
  const TerminalPage({required this.remote, required this.window, super.key});
  final TerminalRemote remote;
  final String window;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _field = TextEditingController();

  /// The composer, which toasts keep clear of.
  final GlobalKey _barKey = GlobalKey();
  final _scroll = ScrollController();
  late final VoidCallback _unwatch;

  /// A shell's long lines reflow to the phone's width; a full-screen program
  /// (a coding agent) lays out to its own width, so its lines stay whole.
  late bool _wrap = remote.window(widget.window)?.agent == null;
  bool _sending = false;

  /// The close button was tapped: the page asks above its bar.
  bool _closing = false;

  /// A close was sent, and the computer hasn't answered yet.
  bool _closeSent = false;

  /// Lines numbered from the first one the phone saw: the ones from
  /// [_anchor] on go below the scroll view's center, so lines arriving
  /// there never move what's above.
  int? _anchor;
  bool _atBottom = true;

  /// Each line's spans and visible length, for [_palette].
  final _spans = <String, (List<TextSpan>, int)>{};
  TermColors? _palette;

  TerminalRemote get remote => widget.remote;

  @override
  void initState() {
    super.initState();
    _field.addListener(() => setState(() {}));
    _scroll.addListener(() {
      final p = _scroll.position;
      _atBottom = p.pixels >= p.maxScrollExtent - 8;
    });
    _unwatch = remote.watchWindow(widget.window);
  }

  @override
  void dispose() {
    _unwatch();
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _field.text;
    if (text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await remote.send(widget.window, text);
      _field.clear();
    } on Object catch (e) {
      if (mounted) termToast(context, e, above: _barKey);
    }
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _close(TermWindow w) async {
    setState(() => _closeSent = true);
    final closed = await closeWindow(context, remote, w);
    if (!mounted) return;
    setState(() => _closing = _closeSent = false);
    if (closed) await Navigator.of(context).maybePop();
  }

  Future<void> _press(String key) async {
    unawaited(HapticFeedback.selectionClick());
    try {
      await remote.press(widget.window, key);
    } on Object catch (e) {
      if (mounted) termToast(context, e, above: _barKey);
    }
  }

  (List<TextSpan>, int) _line(String line, TermColors palette) {
    if (!identical(palette, _palette)) {
      _palette = palette;
      _spans.clear();
    }
    return _spans[line] ??= () {
      final spans = ansiSpans(line, palette);
      return (spans, spans.fold<int>(0, (n, s) => n + (s.text?.length ?? 0)));
    }();
  }

  Widget _key(String label, String key) {
    void press() => unawaited(_press(key));
    return Expanded(
      child: TextFieldTapRegion(
        // A 34pt cap in a 44pt tap target: the gap around it presses it too,
        // and the press shows on the cap alone.
        child: GestureDetector(
          key: ValueKey('key-$key'),
          behavior: HitTestBehavior.opaque,
          onTap: press,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 5),
            child: Material(
              color: const Color(0xFF262833),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7),
                side: const BorderSide(color: C.line2),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: press,
                child: SizedBox(
                  height: 34,
                  child: Center(child: Text(label, style: const TextStyle(fontSize: 13))),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _followBottom() {
    if (!_atBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final p = _scroll.position;
      if (p.pixels != p.maxScrollExtent) _scroll.jumpTo(p.maxScrollExtent);
    });
  }

  Widget _screen(TermScreen s, TermColors palette) {
    final lines = s.lines;
    final end = s.base + lines.length;
    // A cleared screen: start over at its end.
    final anchor = _anchor = (_anchor == null || _anchor! > end) ? end : _anchor!;
    final above = (anchor - s.base).clamp(0, lines.length);
    final style = _mono.copyWith(color: palette.foreground);
    var widest = 0;
    if (!_wrap) {
      for (final l in lines) {
        final n = _line(l, palette).$2;
        if (n > widest) widest = n;
      }
    }

    Widget row(int i) {
      final text = Text.rich(
        TextSpan(children: _line(lines[i], palette).$1),
        style: style,
        strutStyle: _monoStrut,
        softWrap: _wrap,
        maxLines: _wrap ? null : 1,
      );
      return Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: text);
    }

    const center = ValueKey('center');
    SliverChildBuilderDelegate delegate(int count, int Function(int) at) =>
        SliverChildBuilderDelegate((_, i) => row(at(i)), childCount: count);
    Widget sliver(int count, int Function(int) at, {Key? key}) => _wrap
        ? SliverList(key: key, delegate: delegate(count, at))
        : SliverFixedExtentList(key: key, itemExtent: _lineHeight, delegate: delegate(count, at));

    _followBottom();
    final view = CustomScrollView(
      controller: _scroll,
      center: center,
      // The center at the bottom: the screen's end shows first.
      anchor: 1,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        // Before the center: laid out upwards from it.
        sliver(above, (i) => above - 1 - i),
        sliver(lines.length - above, (i) => above + i, key: center),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
      ],
    );
    return ColoredBox(
      color: palette.background,
      child: SelectionArea(
        child: _wrap
            ? view
            : LayoutBuilder(
                builder: (context, box) {
                  final tp = TextPainter(
                    text: const TextSpan(text: 'M', style: _mono),
                    textDirection: TextDirection.ltr,
                  )..layout();
                  final width = tp.width * widest + 24;
                  tp.dispose();
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(width: width < box.maxWidth ? box.maxWidth : width, child: view),
                  );
                },
              ),
      ),
    );
  }

  /// Why [w]'s screen doesn't show, and what would show it.
  Widget _unreadable(TermWindow w) {
    final tmux = remote.terminals.where((t) => t.id == 'tmux').firstOrNull;
    final fix = tmux != null && tmux.state == TermState.missing
        ? tmux.note
        : 'Sessions you start from the phone open in tmux, which can.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "${termLabel(w.app)} can't share its screen.",
              key: const ValueKey('screen-unreadable'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: C.dim, height: 1.5),
            ),
            const SizedBox(height: 8),
            Text(
              fix,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: C.dim2, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  /// The keys a terminal program needs, if the window's terminal can press
  /// them, and the composer, if it can type.
  Widget _bar({required bool enabled, required bool keys, required bool compose, required bool canSend}) => Container(
    key: _barKey,
    decoration: const BoxDecoration(
      color: C.bar,
      border: Border(top: BorderSide(color: C.line)),
    ),
    padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (keys && enabled)
            Padding(
              padding: EdgeInsets.only(bottom: compose ? 3 : 0, right: 4),
              child: Row(
                children: [
                  _key('Esc', 'esc'),
                  _key('Tab', 'tab'),
                  _key('↑', 'up'),
                  _key('↓', 'down'),
                  _key('⏎', 'enter'),
                  _key('^C', 'ctrl+c'),
                ],
              ),
            ),
          if (compose)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const ValueKey('term-input'),
                    onTapOutside: dismissKeyboard,
                    controller: _field,
                    minLines: 1,
                    maxLines: 6,
                    enabled: enabled,
                    autocorrect: false,
                    style: const TextStyle(fontSize: 16, height: 1.4),
                    decoration: plainInput.copyWith(
                      hintText: 'Type a line…',
                      hintStyle: const TextStyle(color: C.dim2),
                      // 48 tall, like the send button, so one line sits on its center.
                      contentPadding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                  ),
                ),
                // Part of the field for tap-outside: sending keeps the
                // keyboard up for the next line.
                TextFieldTapRegion(
                  child: IconButton(
                    key: const ValueKey('term-send'),
                    tooltip: 'Send (types it, then Enter)',
                    onPressed: canSend ? () => unawaited(_send()) : null,
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: remote,
    builder: (context, _) {
      final w = remote.window(widget.window);
      final online = remote.online;
      final gone = online && !remote.fromCache && w == null;
      final screen = remote.screen(widget.window);
      final palette = remote.colors[widget.window] ?? TermColors.fallback;
      final note = linkNote(remote);
      // A window not in the list yet (just launched) can do everything.
      bool can(TermCap c) => w?.can(c) ?? true;
      final readable = can(TermCap.read);
      final keys = can(TermCap.keys);
      final compose = can(TermCap.line) || can(TermCap.type);
      final canSend = online && !gone && !_sending && _field.text.trim().isNotEmpty;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            w == null ? 'Terminal' : (w.title.isEmpty ? w.program : w.title),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (w != null && online && w.can(TermCap.close))
              IconButton(
                key: const ValueKey('close-window'),
                tooltip: 'Close window',
                onPressed: _closeSent ? null : () => setState(() => _closing = true),
                icon: const Icon(Icons.close, color: C.dim),
              ),
            if (readable)
              IconButton(
                tooltip: _wrap ? "Don't wrap lines" : 'Wrap lines',
                onPressed: () => setState(() => _wrap = !_wrap),
                icon: Icon(Icons.wrap_text, color: _wrap ? C.accent : C.dim),
              ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Reveal(visible: note != null, child: note ?? const SizedBox.shrink()),
            SwitchBanner(remote: remote, window: widget.window),
            Expanded(
              child: gone
                  ? const Center(
                      child: Text('This window has closed.', style: TextStyle(color: C.dim)),
                    )
                  : !readable
                  ? _unreadable(w!)
                  : screen == null
                  ? Center(
                      child: online
                          ? const CircularProgressIndicator(strokeWidth: 2)
                          : const Text('No screen yet.', style: TextStyle(color: C.dim)),
                    )
                  : _screen(screen, palette),
            ),
            Reveal(
              visible: _closing && w != null && online && !gone,
              child: w == null
                  ? const SizedBox.shrink()
                  : CloseConfirm(
                      remote: remote,
                      window: w,
                      onCancel: () => setState(() => _closing = false),
                      onClose: () => unawaited(_close(w)),
                      closing: _closeSent,
                    ),
            ),
            if (keys || compose) _bar(enabled: online && !gone, keys: keys, compose: compose, canSend: canSend),
          ],
        ),
      );
    },
  );
}

/// A new terminal window in one of the computer's projects (or any folder typed in),
/// or in a new project folder made under one of the computer's Project folders,
/// starting the computer's coding agent unless turned off. Pops the new window's
/// key and whether the agent runs in it.
class NewSessionSheet extends StatefulWidget {
  const NewSessionSheet({required this.remote, super.key});
  final TerminalRemote remote;

  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<NewSessionSheet> {
  final _query = TextEditingController();
  bool _agent = true;
  String? _launching;

  /// Making a new project: its [_name] and the computer's root it goes in (the
  /// first while none is picked or the picked one is gone).
  bool _creating = false;
  final _name = TextEditingController();
  String? _rootPath;

  TerminalRemote get remote => widget.remote;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    _name.dispose();
    super.dispose();
  }

  InputDecoration _field(String hint, IconData icon) => InputDecoration(
    hintText: hint,
    prefixIcon: Icon(icon, size: 20, color: C.dim),
    filled: true,
    fillColor: C.field,
    isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
  );

  String? get _typed => typedPath(_query.text, remote.home);

  Future<void> _launch(String cwd) async {
    if (_launching != null) return;
    setState(() => _launching = cwd);
    try {
      final agent = _agent;
      final window = await remote.launch(cwd, startAgent: agent);
      if (mounted) Navigator.of(context).pop((window: window, agent: agent));
    } on Object catch (e) {
      if (mounted) {
        setState(() => _launching = null);
        termToast(context, e);
      }
    }
  }

  /// Makes [_name] under [root] on the computer and opens a window there, as [_launch].
  Future<void> _create(String root) async {
    if (_launching != null) return;
    setState(() => _launching = root);
    try {
      final agent = _agent;
      final window = await remote.create(root, _name.text.trim(), startAgent: agent);
      if (mounted) Navigator.of(context).pop((window: window, agent: agent));
    } on Object catch (e) {
      if (mounted) {
        setState(() => _launching = null);
        termToast(context, e);
      }
    }
  }

  /// Name the project and pick the folder it goes in.
  List<Widget> _createForm(Widget? note) {
    final roots = remote.roots ?? const <String>[];
    final root = roots.contains(_rootPath) ? _rootPath : roots.firstOrNull;
    final busy = _launching != null;
    final ready = remote.online && _name.text.trim().isNotEmpty && !busy;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: TextField(
          key: const ValueKey('project-name'),
          onTapOutside: dismissKeyboard,
          controller: _name,
          autofocus: true,
          autocorrect: false,
          style: const TextStyle(fontSize: 15),
          decoration: _field('Project name', Icons.create_new_folder_outlined),
        ),
      ),
      Reveal(visible: note != null, child: note ?? const SizedBox.shrink()),
      Expanded(
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          children: [
            const Text('In', style: TextStyle(fontSize: 12, color: C.dim)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in roots)
                  ChoiceChip(
                    label: Text(shortPath(remote, r)),
                    selected: r == root,
                    onSelected: (_) => setState(() => _rootPath = r),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(onPressed: busy ? null : () => setState(() => _creating = false), child: const Text('Back')),
                const Spacer(),
                FilledButton(
                  onPressed: root != null && ready ? () => unawaited(_create(root)) : null,
                  child: busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Create and open'),
                ),
              ],
            ),
          ],
        ),
      ),
    ];
  }

  /// Find a project (or type a path) and open a window there; or start a
  /// new project.
  List<Widget> _pickList(Widget? note) {
    final words = _query.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final open = {for (final w in remote.windows) w.cwd};
    final places = [
      ...open.where((p) => p.isNotEmpty && p != remote.home),
      ...remote.projects.where((p) => !open.contains(p)),
    ].where((p) => words.every(shortPath(remote, p).toLowerCase().contains)).toList();
    final typed = _typed;
    // null: a computer that predates Project folders, and can't make a project.
    final roots = remote.roots;
    final noRoots = roots != null && roots.isEmpty;
    final noRootsHint = remote.online && noRoots && places.isEmpty && typed == null;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: TextField(
          key: const ValueKey('session-folder'),
          onTapOutside: dismissKeyboard,
          controller: _query,
          autocorrect: false,
          style: const TextStyle(fontSize: 15),
          decoration: _field('Find a project, or type ~/path', Icons.folder_outlined),
        ),
      ),
      Reveal(visible: note != null, child: note ?? const SizedBox.shrink()),
      if (noRootsHint)
        const Padding(
          key: ValueKey('no-roots'),
          padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            'No project folders yet. On your computer, open PocketTerm → Settings → Project folders and add '
            'the folders that hold your projects. You can still type a ~/path above.',
            style: TextStyle(fontSize: 13, color: C.dim, height: 1.4),
          ),
        ),
      Expanded(
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            if (_query.text.isEmpty && roots != null)
              ListTile(
                key: const ValueKey('new-project'),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                enabled: remote.online && roots.isNotEmpty && _launching == null,
                onTap: () => setState(() => _creating = true),
                leading: const Icon(Icons.create_new_folder_outlined, size: 18, color: C.dim2),
                title: const Text('New project…', style: TextStyle(fontSize: 14)),
                // The hint above says it already.
                subtitle: noRoots && !noRootsHint
                    ? const Text(
                        'Add a project folder in PocketTerm on your computer: Settings → Project folders',
                        style: TextStyle(fontSize: 12, color: C.dim),
                      )
                    : null,
              ),
            for (final p in [?typed, ...places])
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                enabled: remote.online,
                onTap: () => unawaited(_launch(p)),
                leading: Icon(open.contains(p) ? Icons.terminal : Icons.folder_outlined, size: 18, color: C.dim2),
                title: Text(shortPath(remote, p), style: const TextStyle(fontSize: 14)),
                trailing: _launching == p
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
              ),
          ],
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: remote,
    builder: (context, _) {
      final note = linkNote(remote);
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => SizedBox(
              // 70% of the screen, less whatever the keyboard leaves no
              // room for (the sheet already starts below the notch).
              height: min(MediaQuery.sizeOf(context).height * .7, box.maxHeight - 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(20, sheetTop, 20, remote.opensIn == null ? 4 : 0),
                    child: Text(_creating ? 'New project' : 'New session', style: sheetTitleStyle),
                  ),
                  if (remote.opensIn case final opensIn?)
                    Padding(
                      key: const ValueKey('opens-in'),
                      padding: const EdgeInsets.fromLTRB(20, 2, 20, 4),
                      child: Text('Opens in $opensIn', style: const TextStyle(fontSize: 13, color: C.dim)),
                    ),
                  SwitchListTile(
                    key: const ValueKey('start-agent'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    value: _agent,
                    onChanged: (v) => setState(() => _agent = v),
                    title: Text('Start ${remote.agent.label}', style: const TextStyle(fontSize: 15)),
                    subtitle: const Text('Off: just a shell', style: TextStyle(fontSize: 12, color: C.dim)),
                  ),
                  if (_creating) ..._createForm(note) else ..._pickList(note),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
