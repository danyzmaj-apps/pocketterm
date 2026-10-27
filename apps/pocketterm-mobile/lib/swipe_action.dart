import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/motion.dart';

/// What a [SwipeAction] shows its action on, and its icon and label in.
Color get swipeActionColor => C.error;
Color get swipeActionText => C.win;

/// One action behind a [SwipeAction]'s row: an icon over [label], on [color] (the close action's red when null).
/// [busy]: it went and hasn't been answered yet: a spinner, the row held open, not to be swiped or tapped.
@immutable
class SwipeItem {
  const SwipeItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.busy = false,
    this.key,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool busy;
  final Key? key;
}

/// A list row that slides left under the finger, showing its [actions] side
/// by side behind its right end, the last at the edge. Let go past 40% of their
/// width, or flung left, it slides open and stays; else it slides back.
/// Open, each action is one tap; a tap on the row or a swipe right shuts it.
///
/// Whether it's open is the owner's ([open]: it slides to match), and
/// [onOpen] says when the finger opened or shut it; [onSwipe], that a finger
/// started moving it. An action [SwipeItem.busy] holds it open and still. Not
/// [enabled]: it doesn't move.
class SwipeAction extends StatefulWidget {
  const SwipeAction({
    required this.open,
    required this.onOpen,
    required this.actions,
    required this.child,
    this.onSwipe,
    this.enabled = true,
    super.key,
  });
  final bool open;
  final ValueChanged<bool> onOpen;
  final VoidCallback? onSwipe;
  final List<SwipeItem> actions;
  final bool enabled;
  final Widget child;

  /// How wide each action is, open.
  static const width = 84.0;

  @override
  State<SwipeAction> createState() => _SwipeActionState();
}

class _SwipeActionState extends State<SwipeAction> with SingleTickerProviderStateMixin {
  /// Past open, the row follows the finger a third as far, up to this much of
  /// the action's width.
  static const _stretch = 1.4;

  /// Where letting go opens it, as a share of the action's width.
  static const _snap = .4;

  /// A fling this fast (px/s) opens or shuts it wherever it is.
  static const _fling = 700.0;

  /// How much of the action shows, as a share of its width; [_to]: where
  /// it's sliding to.
  late final _shown = AnimationController(vsync: this, upperBound: _stretch, value: widget.open ? 1 : 0);
  double? _to;
  bool _dragging = false;

  bool get _busy => widget.actions.any((a) => a.busy);
  bool get _movable => widget.enabled && !_busy;

  /// All the actions' width, open.
  double get _width => SwipeAction.width * widget.actions.length;

  @override
  void didUpdateWidget(SwipeAction old) {
    super.didUpdateWidget(old);
    if (_dragging && !_movable) _dragging = false;
    if (!_dragging) _settle(widget.open);
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  /// Slides it open or shut, unless it's there or on its way.
  void _settle(bool open) {
    final to = open ? 1.0 : 0.0;
    if (_shown.isAnimating ? _to == to : _shown.value == to) return;
    _to = to;
    _shown.animateTo(to, duration: Motion.of(context), curve: Motion.ease);
  }

  void _start(DragStartDetails _) {
    _dragging = true;
    _shown.stop();
    widget.onSwipe?.call();
  }

  void _update(DragUpdateDetails d) {
    if (!_dragging) return;
    // Toward the row's start (left; right when right to left) is positive: more of the action.
    final delta = -d.primaryDelta! * _ltr / _width;
    final v = _shown.value;
    _shown.value = (v + (delta > 0 && v >= 1 ? delta / 3 : delta)).clamp(0, _stretch);
  }

  /// 1 left to right, -1 right to left: the action sits at the row's end either way.
  double get _ltr => Directionality.of(context) == TextDirection.rtl ? -1 : 1;

  void _end(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    final velocity = (d.primaryVelocity ?? 0) * _ltr;
    // A fling, however far, only opens it: the action is still a tap away.
    final open = velocity < -_fling || (velocity <= _fling && _shown.value >= _snap);
    _settle(open);
    if (open && !widget.open) unawaited(HapticFeedback.selectionClick());
    if (open != widget.open) widget.onOpen(open);
  }

  void _cancel() {
    if (!_dragging) return;
    _dragging = false;
    _settle(widget.open);
  }

  void _shut() {
    _settle(false);
    if (widget.open) widget.onOpen(false);
  }

  @override
  Widget build(BuildContext context) {
    final movable = _movable;
    return GestureDetector(
      onHorizontalDragStart: movable ? _start : null,
      onHorizontalDragUpdate: movable ? _update : null,
      onHorizontalDragEnd: movable ? _end : null,
      onHorizontalDragCancel: movable ? _cancel : null,
      child: AnimatedBuilder(
        animation: _shown,
        // Its own ink layer, so a tap's splash moves with the row.
        child: Material(type: MaterialType.transparency, child: widget.child),
        builder: (context, row) {
          final shown = _shown.value * _width;
          return Stack(
            children: [
              if (shown > 0) PositionedDirectional(top: 0, bottom: 0, end: 0, width: shown, child: _tray()),
              Transform.translate(
                offset: Offset(-shown * _ltr, 0),
                child: Stack(
                  children: [
                    row!,
                    // Open, a tap on the row shuts it instead of opening it.
                    if (shown > 0)
                      Positioned.fill(
                        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _busy ? null : _shut),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// The actions, as wide as open from the row's edge whatever shows of them, each sharing what shows.
  Widget _tray() => ClipRect(
    child: OverflowBox(
      alignment: AlignmentDirectional.centerEnd,
      minWidth: _width,
      maxWidth: _width,
      child: Row(children: [for (final a in widget.actions) Expanded(child: _action(a))]),
    ),
  );

  Widget _action(SwipeItem a) => Material(
    color: a.color ?? swipeActionColor,
    child: InkWell(
      key: a.key,
      onTap: _busy ? null : a.onTap,
      child: Opacity(
        opacity: _shown.value.clamp(0, 1),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox.square(
                dimension: 22,
                child: a.busy
                    ? Padding(
                        padding: const EdgeInsets.all(3),
                        child: CircularProgressIndicator(strokeWidth: 2, color: swipeActionText),
                      )
                    : Icon(a.icon, size: 22, color: swipeActionText),
              ),
              const SizedBox(height: 4),
              Text(
                a.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: swipeActionText),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
