import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';
import 'package:pocketterm_mobile/e2e_hooks.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The first-use tips, in the order they show: the switch tour first, then the list's, then the conversation page's.
enum Tip {
  switchOpen('switch-open'),
  switchButton('switch-button'),
  switchDone('switch-done'),
  projectHeading('project-heading'),
  swipeRow('swipe-row'),
  newSession('new-session'),
  slash('slash'),
  queue('queue'),
  follow('follow'),
  openScreen('open-screen');

  const Tip(this.id);
  final String id;

  /// A step of the switch tour: while it waits on its page and isn't in view, no later tip shows there.
  bool get tour => this == switchOpen || this == switchDone;

  String get caption => switch (this) {
    switchOpen => 'This session shows only its screen. Tap it to open.',
    switchButton =>
      'Turns this into a conversation, with chat, approvals and pushes. '
          'omp restarts on the same conversation; Claude Code just reloads.',
    switchDone => 'Now it’s a conversation. Tap to open it.',
    projectHeading => 'Tap to fold this project. Long-press for its menu.',
    swipeRow => 'Swipe left to end the session or close the window.',
    newSession => 'Start your agent or a shell in any project.',
    slash => 'Type / for slash commands.',
    queue => 'Off: your prompt steers the agent now. On: it waits until the run ends.',
    follow => isIos ? 'Follow this session on your Lock Screen.' : 'Follow this session in your notifications.',
    openScreen => 'See the raw terminal screen.',
  };
}

/// Which tips this install has seen, kept in [SharedPreferences] (per phone, not per account). None shows until
/// [answered]: a fresh install first asks whether to have them ([askForTour]). With `startSeen` a fresh install
/// starts answered with every tip seen, so the end-to-end flows aren't held up by them (E2E debug builds only),
/// until Show tips again.
class CoachController extends ChangeNotifier {
  CoachController(this._prefs, {@visibleForTesting bool startSeen = e2eBuild})
    : _answered = startSeen || _prefs.getStringList(seenKey) != null,
      _seen = {
        ...?_prefs.getStringList(seenKey) ?? (startSeen ? [for (final t in Tip.values) t.id] : null),
      };

  /// The seen ids; kept from the first answer on (empty for Show me), so a missing list is a question not answered.
  static const seenKey = 'pocketterm_tips_seen';

  final SharedPreferences _prefs;
  final Set<String> _seen;

  bool seen(Tip tip) => _seen.contains(tip.id);

  /// Whether the person said whether they want the tips (or brought them back): until then none shows.
  bool get answered => _answered;
  bool _answered;

  /// The answer to [askForTour]: with [tour] the tips show from the first, without it they're all seen.
  Future<void> answer({required bool tour}) async {
    if (tour) {
      await reset();
      return;
    }
    _answered = true;
    _seen.addAll([for (final t in Tip.values) t.id]);
    notifyListeners();
    await _prefs.setStringList(seenKey, [..._seen]);
  }

  /// The window a switch to the conversation view just turned into a session: its row gets [Tip.switchDone].
  String? get switchedWindow => _switchedWindow;
  String? _switchedWindow;

  void switched(String window) {
    _switchedWindow = window;
    notifyListeners();
  }

  Future<void> markSeen(Tip tip) async {
    if (!_seen.add(tip.id)) return;
    notifyListeners();
    await _prefs.setStringList(seenKey, [..._seen]);
  }

  /// Every tip shows again, without asking first.
  Future<void> reset() async {
    _answered = true;
    _seen.clear();
    notifyListeners();
    // Kept empty rather than removed: no list is a fresh install, which asks first ([answered]).
    await _prefs.setStringList(seenKey, const []);
  }
}

/// Asks whether to have the first-use tips, the first time the list shows: in iOS's way a sheet, in Android's a
/// dialog. Only its two buttons answer it (true: Show me); null when it went another way (the page under it went).
Future<bool?> askForTour(BuildContext context) {
  const title = 'New here?';
  const text = 'Want a quick tour? A few tips point out what you can tap, one at a time.';
  if (!isIos) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => PopScope(
        canPop: false,
        child: AlertDialog(
          key: const ValueKey('tour-ask'),
          backgroundColor: M.containerHigh,
          title: const Text(title),
          content: const Text(text, style: TextStyle(color: C.dim, height: 1.4)),
          actions: [
            TextButton(
              key: const ValueKey('tour-no'),
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('No thanks'),
            ),
            TextButton(
              key: const ValueKey('tour-yes'),
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('Show me'),
            ),
          ],
        ),
      ),
    );
  }
  return showAppSheet<bool>(
    context,
    dismissible: false,
    builder: (sheet) => SafeArea(
      key: const ValueKey('tour-ask'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, sheetTop, 24, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(title, textAlign: TextAlign.center, style: sheetTitleStyle),
            const SizedBox(height: 8),
            const Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: C.dim, height: 1.4),
            ),
            const SizedBox(height: 20),
            FilledButton(
              key: const ValueKey('tour-yes'),
              onPressed: () => Navigator.of(sheet).pop(true),
              child: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Show me')),
            ),
            const SizedBox(height: 6),
            TextButton(
              key: const ValueKey('tour-no'),
              onPressed: () => Navigator.of(sheet).pop(false),
              child: const Text('No thanks'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Shows the tips of the [CoachTarget]s below it, one at a time, over everything [child] shows: the first unseen
/// tip whose target sits still in view on a page that has settled (no route moving, no sheet or menu over it, no
/// keyboard up). Goes above the app's navigator ([MaterialApp.builder]).
class Coach extends StatefulWidget {
  const Coach({required this.controller, required this.child, super.key});
  final CoachController controller;
  final Widget child;

  /// The tips' controller, if the app shows tips.
  static CoachController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_CoachScope>()?.coach.widget.controller;

  @override
  State<Coach> createState() => _CoachState();
}

class _CoachState extends State<Coach> {
  CoachController get _controller => widget.controller;

  final _targets = <_CoachTargetState>{};

  /// How often the targets are looked at while one may show.
  static const _every = Duration(milliseconds: 300);
  Timer? _timer;

  _CoachTargetState? _showing;

  /// The target about to show and where it was: it shows once it's still there a tick later.
  (_CoachTargetState, Rect)? _pending;

  ScrollPosition? _scroll;

  /// Where the shown tip's target was when last built.
  Rect? _drawn;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_wake);
  }

  @override
  void didUpdateWidget(Coach old) {
    super.didUpdateWidget(old);
    if (old.controller == _controller) return;
    old.controller.removeListener(_wake);
    _controller.addListener(_wake);
  }

  @override
  void dispose() {
    _controller.removeListener(_wake);
    _timer?.cancel();
    _scroll?.removeListener(_moved);
    super.dispose();
  }

  void _register(_CoachTargetState t) {
    _targets.add(t);
    _wake();
  }

  void _unregister(_CoachTargetState t) {
    _targets.remove(t);
    if (_pending?.$1 == t) _pending = null;
    if (_showing == t) _hide();
  }

  bool get _waiting =>
      _showing != null || (_controller.answered && _targets.any((t) => !_controller.seen(t.widget.tip)));

  /// Looks at the targets while a tip may show.
  void _wake() {
    if (!mounted) return;
    if (_showing case final t? when _controller.seen(t.widget.tip)) _hide();
    if (_timer != null || !_waiting) return;
    _timer = Timer.periodic(_every, (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    if (!_waiting) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (_showing case final t?) {
      final rect = _rect(t);
      if (keyboard || !_settled(t) || rect == null) {
        _hide();
      } else if (rect != _drawn) {
        setState(() {}); // Wherever it is now.
      }
      return;
    }
    if (keyboard) {
      _pending = null;
      return;
    }
    final candidates = _targets.where((t) => !_controller.seen(t.widget.tip) && _settled(t)).toList()
      ..sort((a, b) => a.widget.tip.index.compareTo(b.widget.tip.index));
    for (final t in candidates) {
      final rect = _rect(t);
      if (rect == null) {
        if (t.widget.tip.tour) break;
        continue;
      }
      if (_pending case (final p, final r) when p == t && r == rect) {
        _show(t);
      } else {
        _pending = (t, rect);
      }
      return;
    }
    _pending = null;
  }

  void _show(_CoachTargetState t) {
    _pending = null;
    _scroll = Scrollable.maybeOf(t.context)?.position?..addListener(_moved);
    setState(() => _showing = t);
  }

  void _hide() {
    _scroll?.removeListener(_moved);
    _scroll = null;
    _showing = null;
    _rebuild();
  }

  void _moved() => _rebuild();

  /// Builds again; mid-frame (a target leaving the tree, a list laying out), after it.
  void _rebuild() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle ||
        SchedulerBinding.instance.schedulerPhase == SchedulerPhase.postFrameCallbacks) {
      setState(() {});
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  /// Seen: the tip goes, and the next one may show.
  void _dismiss() {
    final t = _showing;
    if (t == null) return;
    _hide();
    unawaited(_controller.markSeen(t.widget.tip));
  }

  /// A finger went down on [t]: its tip, if showing, has done its job.
  void _touched(_CoachTargetState t) {
    if (_showing == t) _dismiss();
  }

  /// [t]'s page is the one in front, not moving, nothing over it.
  static bool _settled(_CoachTargetState t) {
    final route = ModalRoute.of(t.context);
    if (route == null) return true;
    return route.isCurrent &&
        (route.animation?.status ?? AnimationStatus.completed) == AnimationStatus.completed &&
        (route.secondaryAnimation?.status ?? AnimationStatus.dismissed) == AnimationStatus.dismissed;
  }

  /// Where [t] is, in this widget's box; null unless it's wholly in view (in its list's viewport, if in one).
  Rect? _rect(_CoachTargetState t) {
    final me = context.findRenderObject();
    final box = t.context.findRenderObject();
    if (me is! RenderBox || box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) return null;
    Rect where(RenderBox b) => b.localToGlobal(Offset.zero, ancestor: me) & b.size;
    final rect = where(box);
    bool inside(Rect r) => r.inflate(.5).contains(rect.topLeft) && r.inflate(.5).contains(rect.bottomRight);
    if (!inside(Offset.zero & me.size)) return null;
    final viewport = Scrollable.maybeOf(t.context)?.context.findRenderObject();
    if (viewport is RenderBox && viewport.hasSize && !inside(where(viewport))) return null;
    return rect;
  }

  @override
  Widget build(BuildContext context) {
    final t = _showing;
    final rect = _drawn = t == null ? null : _rect(t);
    if (t != null) {
      // Laid out after this build: where it ends up this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showing == t && _rect(t) != rect) setState(() {});
      });
    }
    return _CoachScope(
      coach: this,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (t != null && rect != null)
            _Spotlight(
              key: ValueKey(t.widget.tip),
              tip: t.widget.tip,
              hole: RRect.fromRectAndRadius(rect.inflate(t.widget.padding), Radius.circular(t.widget.radius)),
              onDismiss: _dismiss,
            ),
        ],
      ),
    );
  }
}

class _CoachScope extends InheritedWidget {
  const _CoachScope({required this.coach, required super.child});
  final _CoachState coach;

  @override
  bool updateShouldNotify(_CoachScope old) => old.coach != coach;
}

/// A control with a first-use [tip]: a [Coach] above spotlights it the first time it's settled in view. Touching it
/// while it's spotlit does what it always does and counts as seen. Without a [Coach], just [child].
class CoachTarget extends StatefulWidget {
  const CoachTarget({required this.tip, required this.child, this.radius = 14, this.padding = 4, super.key});
  final Tip tip;
  final Widget child;

  /// The cutout's corners, and how far it reaches past the control.
  final double radius;
  final double padding;

  @override
  State<CoachTarget> createState() => _CoachTargetState();
}

class _CoachTargetState extends State<CoachTarget> {
  _CoachState? _coach;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final coach = context.dependOnInheritedWidgetOfExactType<_CoachScope>()?.coach;
    if (coach == _coach) return;
    _coach?._unregister(this);
    _coach = coach;
    coach?._register(this);
  }

  @override
  void didUpdateWidget(CoachTarget old) {
    super.didUpdateWidget(old);
    if (old.tip != widget.tip) _coach?._wake();
  }

  @override
  void dispose() {
    _coach?._unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _coach == null ? widget.child : Listener(onPointerDown: (_) => _coach?._touched(this), child: widget.child);
}

/// The tip over the app: everything dimmed but [hole], which lets touches through to the control, and the caption
/// beside it. Tapping the dimmed part, or Got it, dismisses it.
class _Spotlight extends StatelessWidget {
  const _Spotlight({required this.tip, required this.hole, required this.onDismiss, super.key});
  final Tip tip;
  final RRect hole;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.fast,
      curve: Motion.ease,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: LayoutBuilder(
        builder: (context, box) {
          final size = box.biggest;
          final width = math.min(size.width - 32, 320).toDouble();
          final left = (hole.center.dx - width / 2).clamp(16.0, math.max(16, size.width - 16 - width)).toDouble();
          final below = size.height - padding.bottom - hole.bottom;
          final above = hole.top - padding.top;
          final under = below >= 160 || below >= above;
          return _PassThrough(
            hole: hole,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ExcludeSemantics(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onDismiss,
                    child: CustomPaint(painter: _Dim(hole)),
                  ),
                ),
                Positioned(
                  left: left,
                  width: width,
                  top: under ? hole.bottom + 10 : null,
                  bottom: under ? null : size.height - hole.top + 10,
                  child: _Bubble(tip: tip, onDismiss: onDismiss),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.tip, required this.onDismiss});
  final Tip tip;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    child: Material(
      key: ValueKey('tip-${tip.id}'),
      color: M.containerHigh,
      elevation: isIos ? 0 : 3,
      shadowColor: Colors.black,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(isIos ? 14 : 12),
        side: isIos ? const BorderSide(color: C.line2, width: .5) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(tip.caption, style: const TextStyle(fontSize: 15, color: C.text, height: 1.4)),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const ValueKey('tip-got-it'),
                onPressed: onDismiss,
                child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Dim extends CustomPainter {
  _Dim(this.hole);
  final RRect hole;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..drawPath(
        Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(hole)),
        Paint()..color = const Color(0xA6000000),
      )
      ..drawRRect(
        hole,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = C.accent,
      );
  }

  @override
  bool shouldRepaint(_Dim old) => old.hole != hole;
}

/// Touches in [hole] go to what's under it, not to [child].
class _PassThrough extends SingleChildRenderObjectWidget {
  const _PassThrough({required this.hole, super.child});
  final RRect hole;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPassThrough(hole);

  @override
  void updateRenderObject(BuildContext context, _RenderPassThrough renderObject) => renderObject.hole = hole;
}

class _RenderPassThrough extends RenderProxyBox {
  _RenderPassThrough(this.hole);
  RRect hole;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      !hole.contains(position) && super.hitTest(result, position: position);
}
