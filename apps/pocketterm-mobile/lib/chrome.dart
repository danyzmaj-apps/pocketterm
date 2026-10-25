import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/coach.dart';
import 'package:pocketterm_mobile/motion.dart';

/// The phone app's chrome in each platform's own idiom, all drawn by
/// Flutter: on an iPhone iOS's look (inset grouped lists, a round +), on
/// Android Material 3 (tonal surfaces, a rounded-square + button).
bool get isIos => defaultTargetPlatform == TargetPlatform.iOS;

/// The raised surfaces, in the theme's colors on both platforms (not iOS's
/// pure black or white): Material 3's surface containers.
abstract final class M {
  static Color get container => C.card;
  static Color get containerHigh => Color.lerp(C.card, C.field, .5)!;
}

/// A sheet in the app's one style: radius 28 on top, the raised surface,
/// clear of the notch, a grab handle on top. What [builder] shows starts
/// [sheetTop] below the handle. Not [dismissible], only its own buttons
/// close it (no handle then).
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool dismissible = true,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: isScrollControlled,
  isDismissible: dismissible,
  enableDrag: dismissible,
  useSafeArea: true,
  // Its surface and corners come from the theme ([sheetTheme]), so an open sheet follows a change of theme.
  builder: (context) => PopScope(
    canPop: dismissible,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 20,
          child: dismissible
              ? Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: C.line2, borderRadius: BorderRadius.all(Radius.circular(C.r(2)))),
                    child: const SizedBox(width: 36, height: 4),
                  ),
                )
              : null,
        ),
        Flexible(child: builder(context)),
      ],
    ),
  ),
);

/// A screen-high sheet that slides up from the bottom over everything, under the status bar too: the raised
/// surface, the theme's corners on top, a grab handle, then a row with [title], [actions] and a close button,
/// then what [builder] shows, which fills the rest and stays clear of the home indicator and the keyboard.
/// Dragged down, or closed, it pops null; [dismissible] false leaves only the builder's own buttons to close it
/// (no handle, no close button then). [closeKey] names the close button for tests and Maestro.
Future<T?> showFullscreenModal<T>(
  BuildContext context, {
  required Widget title,
  required WidgetBuilder builder,
  List<Widget> actions = const [],
  bool dismissible = true,
  Key closeKey = const ValueKey('modal-close'),
}) {
  // The sheet's route takes the status bar out of its MediaQuery, and so does a Scaffold with an app bar for its
  // body: its height comes from above the routes, where the app's MediaQuery still has it.
  final statusBar = MediaQuery.viewPaddingOf(Navigator.of(context).context).top;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: dismissible,
    enableDrag: dismissible,
    // Not useSafeArea: the surface runs under the status bar, and its content keeps clear of it below.
    constraints: const BoxConstraints.expand(),
    builder: (context) {
      final media = MediaQuery.of(context);
      final bottom = media.viewInsets.bottom > media.viewPadding.bottom
          ? media.viewInsets.bottom
          : media.viewPadding.bottom;
      return PopScope(
        canPop: dismissible,
        child: Padding(
          padding: EdgeInsets.only(top: statusBar, bottom: bottom),
          // The padding above is already applied: what's inside doesn't add it again.
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 20,
                  child: dismissible
                      ? Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: C.line2,
                              borderRadius: BorderRadius.all(Radius.circular(C.r(2))),
                            ),
                            child: const SizedBox(width: 36, height: 4),
                          ),
                        )
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: DefaultTextStyle(
                          style: sheetTitleStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          child: title,
                        ),
                      ),
                      ...actions,
                      if (dismissible)
                        IconButton(
                          key: closeKey,
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: Icon(Icons.close, color: C.dim),
                        ),
                    ],
                  ),
                ),
                Expanded(child: builder(context)),
              ],
            ),
          ),
        ),
      );
    },
  );
}

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

/// The sheets' surface and corners in the active theme.
BottomSheetThemeData sheetTheme(BottomSheetThemeData base) => base.copyWith(
  backgroundColor: isIos ? M.container : M.containerHigh,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(C.r(sheetRadius)))),
);

/// Room between a sheet's handle and its title.
const sheetTop = 6.0;

/// A sheet's title.
TextStyle get sheetTitleStyle => TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: C.text);

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
                        borderRadius: C.round(Panel.headingRadius),
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
                                Icon(Icons.keyboard_arrow_down_rounded, color: C.dim, size: 28),
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
  static double get radius => C.r(isIos ? 22 : 24);

  /// A heading's press, and the other small pills over the list (the sort
  /// button, the page title).
  static double get headingRadius => C.r(12);

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
        borderRadius: C.round(headingRadius),
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
                  child: Text(C.label(title!), maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
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
              // A hairline keeps a card clear of the page in a light theme; boxy frames it heavily.
              shape: RoundedRectangleBorder(
                borderRadius: C.round(radius),
                side: BorderSide(color: C.divider, width: C.t.shape == ThemeShape.soft ? .5 : C.border),
              ),
              child: AnimatedSize(
                duration: Motion.resize(context),
                curve: Motion.ease,
                alignment: Alignment.topCenter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, row) in children.indexed) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: C.t.shape == ThemeShape.boxy ? 1 : .5,
                          indent: textInset,
                          color: C.divider,
                        ),
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
  static Color get _pressed => Color.lerp(C.accent, C.onAccent, .22)!;
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
      foregroundColor: C.onAccent,
      // Round on a soft theme, as the theme shapes it otherwise.
      shape: C.t.shape == ThemeShape.soft
          ? (isIos ? const CircleBorder() : null)
          : RoundedRectangleBorder(borderRadius: C.round(16)),
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
