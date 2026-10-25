import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';

/// What a [SwipeAction] shows its action on, and its icon and label in.
Color get swipeActionColor => C.error;
Color get swipeActionText => C.win;

/// A list row that slides left under the finger, showing one red action
/// behind its right end: a close icon over [label]. Let go past 40% of the action's
/// width, or flung left, it slides open and stays; else it slides back.
/// Open, the action is one tap ([onAction]); a tap on the row or a swipe
/// right shuts it.
///
/// Whether it's open is the owner's ([open]: it slides to match), and
/// [onOpen] says when the finger opened or shut it; [onSwipe], that a finger
/// started moving it. [busy]: the action went and hasn't been answered yet:
/// a spinner, held open, not to be swiped or tapped. Not [enabled]: it
/// doesn't move.
class SwipeAction extends StatefulWidget {
  const SwipeAction({
    required this.open,
    required this.onOpen,
    required this.label,
    required this.onAction,
    required this.child,
    this.onSwipe,
    this.enabled = true,
    this.busy = false,
    this.actionKey,
    super.key,
  });
  final bool open;
  final ValueChanged<bool> onOpen;
  final VoidCallback? onSwipe;
  final String label;
  final VoidCallback onAction;
  final bool enabled;
  final bool busy;
  final Key? actionKey;
  final Widget child;

  /// How wide the action is, open.
  static const width = 104.0;

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

  bool get _movable => widget.enabled && !widget.busy;

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
    _shown.animateTo(to, duration: Motion.fast, curve: Motion.ease);
  }

  void _start(DragStartDetails _) {
    _dragging = true;
    _shown.stop();
    widget.onSwipe?.call();
  }

  void _update(DragUpdateDetails d) {
    if (!_dragging) return;
    // Toward the row's start (left; right when right to left) is positive: more of the action.
    final delta = -d.primaryDelta! * _ltr / SwipeAction.width;
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
          final shown = _shown.value * SwipeAction.width;
          return Stack(
            children: [
              if (shown > 0) PositionedDirectional(top: 0, bottom: 0, end: 0, width: shown, child: _action()),
              Transform.translate(
                offset: Offset(-shown * _ltr, 0),
                child: Stack(
                  children: [
                    row!,
                    // Open, a tap on the row shuts it instead of opening it.
                    if (shown > 0)
                      Positioned.fill(
                        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.busy ? null : _shut),
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

  Widget _action() => Material(
    color: swipeActionColor,
    child: InkWell(
      key: widget.actionKey,
      onTap: widget.busy ? null : widget.onAction,
      child: ClipRect(
        // As wide as open from the row's edge, whatever shows of it.
        child: OverflowBox(
          alignment: AlignmentDirectional.centerStart,
          minWidth: SwipeAction.width,
          maxWidth: SwipeAction.width,
          child: Opacity(
            opacity: _shown.value.clamp(0, 1),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox.square(
                    dimension: 22,
                    child: widget.busy
                        ? Padding(
                            padding: const EdgeInsets.all(3),
                            child: CircularProgressIndicator(strokeWidth: 2, color: swipeActionText),
                          )
                        : Icon(Icons.close, size: 22, color: swipeActionText),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: swipeActionText),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
