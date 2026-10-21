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
/// clear of the notch.
Future<T?> showAppSheet<T>(BuildContext context, {required WidgetBuilder builder, bool isScrollControlled = false}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useSafeArea: true,
      backgroundColor: isIos ? M.container : M.containerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: builder,
    );

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
/// something (a chevron after it says so).
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 6),
      child: Row(
        children: [
          // Large text sizes: the title gives way, never the account button.
          Expanded(
            child: onTap == null
                ? text
                : Semantics(
                    button: true,
                    child: GestureDetector(
                      onTap: onTap,
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        children: [
                          Flexible(child: text),
                          const SizedBox(width: 4),
                          const Icon(Icons.keyboard_arrow_down_rounded, color: C.dim, size: 28),
                        ],
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
/// heading.
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

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 13,
      fontWeight: isIos ? FontWeight.w400 : FontWeight.w600,
      letterSpacing: isIos ? .2 : .1,
      color: isIos ? C.dim : C.accent,
    );
    final heading = title == null
        ? null
        : InkWell(
            onTap: onTitleTap,
            onLongPress: onTitleLongPress,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 18, 24, 7),
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
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (heading != null && titleTip != null)
          CoachTarget(tip: titleTip!, radius: 12, padding: 0, child: heading)
        else
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(isIos ? 22 : 24)),
              child: AnimatedSize(
                duration: Motion.fast,
                curve: Motion.ease,
                alignment: Alignment.topCenter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, row) in children.indexed) ...[
                      if (i > 0) const Divider(height: 1, thickness: 0.5, indent: 52, color: C.line),
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

/// The +: a round accent button on iPhone, Material 3's rounded-square FAB on Android.
class AddButton extends StatelessWidget {
  const AddButton({required this.tooltip, required this.onPressed, super.key});
  final String tooltip;
  final VoidCallback? onPressed;

  /// Room the lists leave at the bottom, clear of the +.
  static const contentInset = 96.0;

  @override
  Widget build(BuildContext context) => FloatingActionButton(
    key: const ValueKey('add'),
    tooltip: tooltip,
    onPressed: onPressed,
    backgroundColor: C.accent,
    foregroundColor: const Color(0xFF0E0F12),
    shape: isIos ? const CircleBorder() : null,
    elevation: isIos ? 2 : null,
    child: Icon(isIos ? Icons.add_rounded : Icons.add, size: 26),
  );
}
