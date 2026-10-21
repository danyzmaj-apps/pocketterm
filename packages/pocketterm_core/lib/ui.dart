import 'dart:async';

import 'package:flutter/material.dart';

/// The app's palette.
abstract final class C {
  static const win = Color(0xFF17181D);
  static const bar = Color(0xFF1E2027);
  static const field = Color(0xFF1D1F26);
  static const sel = Color(0xFF262B3D);
  static const line = Color(0xFF262933);
  static const line2 = Color(0xFF30343F);
  static const text = Color(0xFFE8E9EE);
  static const dim = Color(0xFF8A8F9C);
  static const dim2 = Color(0xFF5C616E);
  static const accent = Color(0xFF7C9CFF);
  static const ok = Color(0xFF4ADE80);
  static const warn = Color(0xFFFBBF24);
}

ThemeData appTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: base.colorScheme.copyWith(primary: C.accent, surface: C.win),
    textTheme: base.textTheme.apply(bodyColor: C.text, displayColor: C.text),
    textSelectionTheme: const TextSelectionThemeData(cursorColor: C.accent, selectionColor: Color(0x557C9CFF)),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
  );
}

const plainInput = InputDecoration(border: InputBorder.none, isCollapsed: true, contentPadding: EdgeInsets.zero);

/// A boxed field, as on the setup screens.
InputDecoration setupField(String hint) => InputDecoration(
  hintText: hint,
  hintStyle: const TextStyle(color: C.dim2),
  filled: true,
  fillColor: C.field,
  isDense: true,
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: const BorderSide(color: C.line2),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: const BorderSide(color: C.line2),
  ),
);

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
        backgroundColor: C.bar,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFFCA5A5)),
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
                  color: const Color(0xFF1F2A22),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF2C4636)),
                ),
                child: Text(_text ?? '', style: const TextStyle(color: Color(0xFFBBF7D0), fontSize: 13)),
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
