import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketterm_core/theme.dart';

export 'package:pocketterm_core/theme.dart';

/// The app's [ThemeData] for [t]: its colors, and its shape on every
/// Material part (buttons, chips, fields, dialogs, sheets, menus, toasts).
ThemeData appTheme(PtTheme t) {
  final shape = t.shape;
  double r(double radius) => radius < shape.maxRadius ? radius : shape.maxRadius;
  // Pills on a soft theme; a crisp or boxy one caps them like every corner.
  final pill = shape == ThemeShape.soft
      ? const StadiumBorder()
      : RoundedRectangleBorder(borderRadius: BorderRadius.circular(shape.maxRadius));
  final side = BorderSide(color: t.line, width: shape.border);
  final side2 = BorderSide(color: t.line2, width: shape.border);
  final chipLabel = WidgetStateColor.resolveWith(
    (s) => s.contains(WidgetState.selected)
        ? t.onAccent
        : s.contains(WidgetState.disabled)
        ? t.dim
        : t.text,
  );
  final base = ThemeData(brightness: t.brightness, useMaterial3: true, visualDensity: shape.density);
  final text = base.textTheme.apply(bodyColor: t.text, displayColor: t.text);
  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: t.win,
    colorScheme: base.colorScheme.copyWith(
      primary: t.accent,
      onPrimary: t.onAccent,
      secondary: t.accent,
      onSecondary: t.onAccent,
      surface: t.win,
      onSurface: t.text,
      onSurfaceVariant: t.dim,
      surfaceTint: Colors.transparent,
      surfaceContainerLowest: t.win,
      surfaceContainerLow: t.card,
      surfaceContainer: t.card,
      surfaceContainerHigh: t.card,
      surfaceContainerHighest: t.field,
      outline: t.line2,
      outlineVariant: t.line,
      error: t.error,
      onError: t.win,
    ),
    textTheme: text,
    iconTheme: IconThemeData(color: t.dim),
    dividerTheme: DividerThemeData(color: t.divider, thickness: shape == ThemeShape.crisp ? .5 : 1, space: 1),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: t.accent,
      selectionColor: t.accent.withValues(alpha: .33),
      selectionHandleColor: t.accent,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(r(6)),
        border: Border.fromBorderSide(side),
      ),
      textStyle: TextStyle(color: t.text, fontSize: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(backgroundColor: t.accent, foregroundColor: t.onAccent, shape: pill),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: t.accent, shape: pill),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(foregroundColor: t.text, side: side, shape: pill),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(backgroundColor: t.field, foregroundColor: t.text, shape: pill),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: t.dim)),
    // Chips to pick from (answers, folders, Queue): an outlined field until picked, then filled with the accent
    // (with its check where the chip shows one), so the pick reads at a glance in every theme, sent ones too.
    chipTheme: ChipThemeData(
      backgroundColor: t.field,
      disabledColor: t.field,
      selectedColor: t.accent,
      side: WidgetStateBorderSide.resolveWith(
        (s) => s.contains(WidgetState.selected) ? BorderSide(color: t.accent, width: shape.border) : side2,
      ),
      shape: pill,
      labelStyle: TextStyle(color: chipLabel, fontSize: 13),
      secondaryLabelStyle: TextStyle(color: chipLabel, fontSize: 13),
      checkmarkColor: t.onAccent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      hintStyle: TextStyle(color: t.dim2),
      labelStyle: TextStyle(color: t.dim),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.card,
      surfaceTintColor: Colors.transparent,
      // Boxy is kitty's popup: square, a heavy frame.
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(16)), side: side),
      titleTextStyle: text.titleLarge!.copyWith(color: t.text),
      contentTextStyle: text.bodyMedium!.copyWith(color: t.dim, height: 1.4),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(r(28)))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: t.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(10)), side: side),
      textStyle: TextStyle(color: t.text),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(t.card),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(10)), side: side)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.card,
      contentTextStyle: TextStyle(color: t.text),
      actionTextColor: t.accent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(10)), side: side),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: t.accent, linearTrackColor: t.line),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.onAccent : t.dim),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.accent : t.field),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.transparent : t.line2,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(4))),
      side: BorderSide(color: t.line2, width: shape.border < 1.5 ? 1.5 : shape.border),
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
  );
}

const plainInput = InputDecoration(border: InputBorder.none, isCollapsed: true, contentPadding: EdgeInsets.zero);

/// A boxed field, as on the setup screens.
InputDecoration setupField(String hint) {
  final border = OutlineInputBorder(
    borderRadius: C.round(8),
    borderSide: BorderSide(color: C.line2, width: C.border),
  );
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: C.dim2),
    filled: true,
    fillColor: C.field,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: border,
    enabledBorder: border,
    focusedBorder: border.copyWith(
      borderSide: BorderSide(color: C.accent, width: C.border),
    ),
  );
}

/// For fields' `onTapOutside`: a tap anywhere else puts the keyboard away.
/// (A tap on the field itself never counts, unlike a screen-wide tap
/// catcher, which can steal the tap that should focus it.)
void dismissKeyboard(PointerDownEvent _) => FocusManager.instance.primaryFocus?.unfocus();

/// Asks before something that can't be undone ([title], [body]); true when
/// the person presses [action].
Future<bool> confirmDanger(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            style: TextButton.styleFrom(foregroundColor: C.error),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

/// A small bottom toast.
class Toaster extends StatefulWidget {
  const Toaster({required this.child, super.key});
  final Widget child;

  static ToasterState of(BuildContext context) => context.findAncestorStateOfType<ToasterState>()!;

  @override
  State<Toaster> createState() => ToasterState();
}

class ToasterState extends State<Toaster> {
  String? _text;
  Timer? _timer;

  void show(String text) {
    _timer?.cancel();
    setState(() => _text = text);
    _timer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _text = null);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      Positioned(
        left: 0,
        right: 0,
        bottom: 24,
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: _text == null ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Color.alphaBlend(C.ok.withValues(alpha: .12), C.card),
                  borderRadius: C.round(10),
                  border: Border.all(color: C.ok.withValues(alpha: .45), width: C.border),
                ),
                child: Text(_text ?? '', style: TextStyle(color: C.text, fontSize: 13)),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// Hover background for clickable rows.
class Hoverable extends StatefulWidget {
  const Hoverable({required this.builder, this.onTap, super.key});
  // ignore: avoid_positional_boolean_parameters, a builder callback's shape.
  final Widget Function(bool hover) builder;
  final VoidCallback? onTap;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: widget.builder(_hover)),
  );
}

/// A theme in small, for the theme pickers: its background with its accent
/// and its ok, attention and error colors.
class ThemeSwatch extends StatelessWidget {
  const ThemeSwatch(this.choice, {super.key});
  final ThemeChoice choice;

  @override
  Widget build(BuildContext context) => Container(
    width: 48,
    height: 30,
    clipBehavior: Clip.antiAlias,
    foregroundDecoration: BoxDecoration(
      borderRadius: C.round(6),
      border: Border.all(color: C.line2, width: C.border),
    ),
    decoration: BoxDecoration(borderRadius: C.round(6)),
    child: _mini(choice.theme),
  );

  static Widget _mini(PtTheme t) => ColoredBox(
    color: t.win,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          SizedBox(height: 5, child: ColoredBox(color: t.accent)),
          Row(
            spacing: 2,
            children: [
              for (final c in [t.ok, t.warn, t.error])
                Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c,
                    shape: t.shape == ThemeShape.boxy ? BoxShape.rectangle : BoxShape.circle,
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
