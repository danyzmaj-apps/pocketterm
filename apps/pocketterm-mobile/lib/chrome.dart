import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/coach.dart';

/// The phone app's chrome in each platform's own idiom, all drawn by
/// Flutter: on an iPhone iOS's look (inset grouped lists, a round +), on
/// Android Material 3 (tonal surfaces, a rounded-square + button).
bool get isIos => defaultTargetPlatform == TargetPlatform.iOS;

/// The raised surfaces, in the app's dark palette on both platforms (not
/// iOS's pure black): Material 3's surface containers.
abstract final class M {
  static const container = Color(0xFF1C1E25);
  static const containerHigh = Color(0xFF23262F);
}

/// The app's motion: things appearing, going or changing size ease out
/// over [fast]; a section folding open or shut eases in and out ([fold]).
abstract final class Motion {
  static const fast = Duration(milliseconds: 200);
  static const Curve ease = Curves.easeOutCubic;
  static const Curve fold = Curves.easeInOut;
}

/// [child] while [visible], else nothing; it grows in and fades in, and
/// shrinks away and fades out, instead of shoving what's around it in one
/// frame.
class Reveal extends StatelessWidget {
  const Reveal({required this.visible, required this.child, this.curve = Motion.ease, super.key});
  final bool visible;
  final Widget child;
  final Curve curve;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.fast,
    switchInCurve: curve,
    switchOutCurve: curve,
    // Each one grows or shrinks from its top edge as it fades, so what's
    // below slides along with it.
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SizeTransition(sizeFactor: animation, alignment: Alignment.topCenter, child: child),
    ),
    layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
    // Keyed: the switcher tells the one going from the one coming by key,
    // and unkeyed it drops the one going at once.
    child: visible
        ? KeyedSubtree(key: ValueKey((true, child.key)), child: child)
        : const SizedBox(key: ValueKey(false), width: double.infinity),
  );
}

/// A sheet in the app's one style: radius 28 on top, the raised surface,
/// clear of the notch, a grab handle on top. What [builder] shows starts
/// [sheetTop] below the handle.
Future<T?> showAppSheet<T>(BuildContext context, {required WidgetBuilder builder, bool isScrollControlled = false}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useSafeArea: true,
      backgroundColor: isIos ? M.container : M.containerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(sheetRadius))),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(
            height: 20,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(color: C.line2, borderRadius: BorderRadius.all(Radius.circular(2))),
                child: SizedBox(width: 36, height: 4),
              ),
            ),
          ),
          Flexible(child: builder(context)),
        ],
      ),
    );

/// Once a sheet, dialog or menu has gone, the page under it says again where
/// its parts are. Flutter (3.47) drops the semantics geometry of what moved
/// under such a popup's barrier, so a screen reader (and Maestro, which aims
/// by the same tree) went on reading the list where it was before: with the
/// connecting note gone under the computer picker, a tap on a row landed on
/// the project heading below it.
class SemanticsRefresh extends NavigatorObserver {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! PopupRoute || previousRoute is! ModalRoute) return;
    // Disposed means its barrier is out of the tree from this frame on.
    unawaited(
      route.completed.whenComplete(
        () => WidgetsBinding.instance.addPostFrameCallback((_) {
          if (previousRoute.isActive) previousRoute.subtreeContext?.findRenderObject()?.markNeedsSemanticsUpdate();
        }),
      ),
    );
  }
}

/// A sheet's top corners.
const sheetRadius = 28.0;

/// Room between a sheet's handle and its title.
const sheetTop = 6.0;

/// A sheet's title.
const sheetTitleStyle = TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: C.text);

/// A floating toast's margin that keeps it clear of [above] (a page's
/// composer, which is part of the body, so the toast would cover it).
EdgeInsets toastMargin(GlobalKey? above) {
  final box = above?.currentContext?.findRenderObject();
  final height = box is RenderBox && box.hasSize ? box.size.height : 0.0;
  return EdgeInsets.fromLTRB(15, 5, 15, 10 + height);
}

/// A screen's big title, with what goes on its right; [onTap]: it picks
/// something (a chevron after it says so), and a press shows as a rounded
/// pill around the title and chevron.
class PageTitle extends StatelessWidget {
  const PageTitle(this.title, {this.trailing = const [], this.onTap, super.key});
  final String title;
  final List<Widget> trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      // Smaller than iOS's 34pt large title: a computer's full name ("Danijel's MacBook Pro") fits beside the
      // chevron and the account button.
      style: isIos
          ? const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)
          : const TextStyle(fontSize: 24, fontWeight: FontWeight.w400),
    );
    // The pill's inset: the title sits 20 from the screen's edge either way.
    const inset = EdgeInsets.fromLTRB(8, 4, 4, 4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Row(
        children: [
          // Large text sizes: the title gives way, never the account button.
          Expanded(
            child: onTap == null
                ? Padding(padding: inset, child: text)
                : Align(
                    alignment: Alignment.centerLeft,
                    heightFactor: 1,
                    child: Semantics(
                      button: true,
                      child: InkWell(
                        onTap: onTap,
                        borderRadius: BorderRadius.circular(Panel.headingRadius),
                        // At least 48 tall: a tap target both platforms' guidelines accept.
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Padding(
                            padding: inset,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(child: text),
                                const SizedBox(width: 4),
                                const Icon(Icons.keyboard_arrow_down_rounded, color: C.dim, size: 28),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

/// A group of rows: an inset rounded card (iOS's inset grouped list, or a
/// Material 3 tonal surface) with thin separators, under an optional small
/// heading. The card clips its rows, so a press on the first or last row
/// rounds with it.
class Panel extends StatelessWidget {
  const Panel({
    required this.children,
    this.title,
    this.onTitleTap,
    this.onTitleLongPress,
    this.titleTrailing,
    this.titleTip,
    super.key,
  });
  final List<Widget> children;
  final String? title;
  final VoidCallback? onTitleTap;
  final VoidCallback? onTitleLongPress;
  final Widget? titleTrailing;

  /// The first-use tip the heading carries, if any.
  final Tip? titleTip;

  /// The card's corners.
  static double get radius => isIos ? 22 : 24;

  /// A heading's press, and the other small pills over the list (the sort
  /// button, the page title).
  static const headingRadius = 12.0;

  /// Where a row's text starts in the card, which its separator lines up with.
  static const textInset = 56.0;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 13,
      fontWeight: isIos ? FontWeight.w400 : FontWeight.w600,
      letterSpacing: isIos ? .2 : .1,
      color: isIos ? C.dim : C.accent,
    );
    Widget? heading;
    if (title != null) {
      // A pill as wide as the card under it; its text lines up with the rows' icons.
      heading = InkWell(
        onTap: onTitleTap,
        onLongPress: onTitleLongPress,
        borderRadius: BorderRadius.circular(headingRadius),
        // As tall as the platform's smallest tap target; the room above it shrinks to match.
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: isIos ? 44 : 48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 7, 8, 7),
            child: Row(
              children: [
                // A long title (a project folder's name) gives way to what
                // trails it.
                Expanded(
                  child: Text(title!, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                ),
                ?titleTrailing,
              ],
            ),
          ),
        ),
      );
      if (titleTip case final tip?) heading = CoachTarget(tip: tip, radius: headingRadius, padding: 0, child: heading);
      heading = Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: heading);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?heading,
        // Folding opens and shuts the card instead of popping it.
        Reveal(
          visible: children.isNotEmpty,
          curve: Motion.fold,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, title == null ? 8 : 0, 16, 0),
            // A Material, so the rows' ink and list tiles paint on it.
            child: Material(
              color: M.container,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
              child: AnimatedSize(
                duration: Motion.fast,
                curve: Motion.ease,
                alignment: Alignment.topCenter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, row) in children.indexed) ...[
                      if (i > 0) const Divider(height: 1, thickness: 0.5, indent: textInset, color: C.line),
                      row,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The +: a round accent button on iPhone, Material 3's rounded-square FAB on Android. On iPhone it darkens while a
/// finger is on it, as iOS's buttons do; on Android it ripples.
class AddButton extends StatefulWidget {
  const AddButton({required this.tooltip, required this.onPressed, super.key});
  final String tooltip;
  final VoidCallback? onPressed;

  /// Room the lists leave at the bottom, clear of the +.
  static const contentInset = 96.0;

  @override
  State<AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<AddButton> {
  static final Color _pressed = Color.lerp(C.accent, Colors.black, .22)!;
  bool _down = false;

  void _set(bool down) {
    if (down != _down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final button = FloatingActionButton(
      key: const ValueKey('add'),
      tooltip: widget.tooltip,
      onPressed: widget.onPressed,
      backgroundColor: isIos && _down ? _pressed : C.accent,
      foregroundColor: const Color(0xFF0E0F12),
      shape: isIos ? const CircleBorder() : null,
      elevation: isIos ? 2 : null,
      // On iPhone the shadow stays put; the darker fill says it's pressed.
      highlightElevation: isIos ? 2 : null,
      child: Icon(isIos ? Icons.add_rounded : Icons.add, size: 26),
    );
    if (!isIos) return button;
    return Listener(
      onPointerDown: (_) => _set(widget.onPressed != null),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: button,
    );
  }
}
