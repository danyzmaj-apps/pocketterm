import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How a theme's parts are shaped, after the kitty theme it comes from:
/// [soft] round and airy (Catppuccin, Rosé Pine), [crisp] small corners
/// and hairlines (Tokyo Night), [boxy] square, heavy borders and capital
/// labels (Gruvbox).
enum ThemeShape {
  soft(maxRadius: double.infinity, border: 1, caps: false, dividerAlpha: .6, density: VisualDensity.standard),
  crisp(maxRadius: 6, border: .5, caps: false, dividerAlpha: 1, density: VisualDensity.comfortable),
  boxy(maxRadius: 2, border: 2, caps: true, dividerAlpha: 1, density: VisualDensity.standard);

  const ThemeShape({
    required this.maxRadius,
    required this.border,
    required this.caps,
    required this.dividerAlpha,
    required this.density,
  });

  /// The largest corner radius anything gets: a pill on [soft] stays a
  /// pill, on [crisp] it's 6, on [boxy] nearly square.
  final double maxRadius;

  /// Border width of fields, cards and dialogs.
  final double border;

  /// Section and chip labels in capitals.
  final bool caps;

  /// How strongly separators show, from the line color.
  final double dividerAlpha;

  /// Spacing of buttons, fields and list rows.
  final VisualDensity density;
}

/// One theme of the app's chrome (screens, sheets, bars, fields, buttons):
/// a kitty theme's colors and its [shape]. Read the active one through [C]
/// or [appearance].
@immutable
class PtTheme {
  const PtTheme({
    required this.name,
    required this.brightness,
    required this.shape,
    required this.win,
    required this.bar,
    required this.field,
    required this.sel,
    required this.line,
    required this.text,
    required this.dim,
    required this.dim2,
    required this.accent,
    required this.onAccent,
    required this.ok,
    required this.warn,
    required this.error,
    required this.card,
  });

  final String name;
  final Brightness brightness;
  final ThemeShape shape;

  /// The window's background.
  final Color win;

  /// Title, tab and status bars.
  final Color bar;

  /// Text fields and pressed or hovered rows.
  final Color field;

  /// The selected row or tab.
  final Color sel;

  /// Borders and separators.
  final Color line;
  final Color text;

  /// Secondary text.
  final Color dim;

  /// Hints and what's off.
  final Color dim2;
  final Color accent;

  /// Text and icons on [accent].
  final Color onAccent;
  final Color ok;
  final Color warn;
  final Color error;

  /// Raised surfaces: cards, sheets, dialogs, menus.
  final Color card;

  bool get dark => brightness == Brightness.dark;

  /// A field's border: a step stronger than [line].
  Color get line2 => Color.lerp(line, dim2, .3)!;

  /// Separators between rows.
  Color get divider => line.withValues(alpha: shape.dividerAlpha);

  static const mocha = PtTheme(
    name: 'Catppuccin Mocha',
    brightness: Brightness.dark,
    shape: ThemeShape.soft,
    win: Color(0xFF1E1E2E),
    bar: Color(0xFF181825),
    field: Color(0xFF313244),
    sel: Color(0xFF313244),
    line: Color(0xFF45475A),
    text: Color(0xFFCDD6F4),
    dim: Color(0xFF82879E),
    dim2: Color(0xFF71758C),
    accent: Color(0xFFCBA6F7),
    onAccent: Color(0xFF1E1E2E),
    ok: Color(0xFFA6E3A1),
    warn: Color(0xFFFAB387),
    error: Color(0xFFF38BA8),
    card: Color(0xFF181825),
  );

  static const dawn = PtTheme(
    name: 'Rosé Pine Dawn',
    brightness: Brightness.light,
    shape: ThemeShape.soft,
    win: Color(0xFFFAF4ED),
    bar: Color(0xFFF2E9E1),
    field: Color(0xFFF2E9E1),
    sel: Color(0xFFE0D6CB),
    line: Color(0xFFDFDAD9),
    text: Color(0xFF534E73),
    dim: Color(0xFF6F6B89),
    dim2: Color(0xFF837D92),
    accent: Color(0xFF286983),
    onAccent: Color(0xFFFAF4ED),
    ok: Color(0xFF55784D),
    warn: Color(0xFF9E6210),
    error: Color(0xFFAB526C),
    card: Color(0xFFFFFAF3),
  );

  static const tokyoNight = PtTheme(
    name: 'Tokyo Night',
    brightness: Brightness.dark,
    shape: ThemeShape.crisp,
    win: Color(0xFF1A1B26),
    bar: Color(0xFF16161E),
    field: Color(0xFF24283B),
    sel: Color(0xFF24283B),
    line: Color(0xFF2F3549),
    text: Color(0xFFC0CAF5),
    dim: Color(0xFF767DA4),
    dim2: Color(0xFF656F9E),
    accent: Color(0xFF7AA2F7),
    onAccent: Color(0xFF16161E),
    ok: Color(0xFF9ECE6A),
    warn: Color(0xFFFF9E64),
    error: Color(0xFFF7768E),
    card: Color(0xFF16161E),
  );

  static const gruvbox = PtTheme(
    name: 'Gruvbox Material',
    brightness: Brightness.dark,
    shape: ThemeShape.boxy,
    win: Color(0xFF282828),
    bar: Color(0xFF1D2021),
    field: Color(0xFF32302F),
    sel: Color(0xFF32302F),
    line: Color(0xFF45403D),
    text: Color(0xFFD4BE98),
    dim: Color(0xFF928374),
    dim2: Color(0xFF87796D),
    accent: Color(0xFF7DAEA3),
    onAccent: Color(0xFF1D2021),
    ok: Color(0xFFA9B665),
    warn: Color(0xFFD8A657),
    error: Color(0xFFEA6962),
    card: Color(0xFF1D2021),
  );
}

/// The theme the person picked; [mocha] until they pick one.
enum ThemeChoice {
  mocha('Catppuccin Mocha'),
  dawn('Rosé Pine Dawn'),
  tokyoNight('Tokyo Night'),
  gruvbox('Gruvbox Material');

  const ThemeChoice(this.label);
  final String label;

  /// The theme this choice shows.
  PtTheme get theme => switch (this) {
    mocha => PtTheme.mocha,
    dawn => PtTheme.dawn,
    tokyoNight => PtTheme.tokyoNight,
    gruvbox => PtTheme.gruvbox,
  };
}

/// The active theme and the choice behind it, kept per device; notifies
/// when the choice changes. The app reads it through [appearance].
class Appearance extends ChangeNotifier {
  @visibleForTesting
  Appearance();

  /// The preference the choice is kept under.
  static const prefsKey = 'theme';

  SharedPreferences? _prefs;
  ThemeChoice _choice = ThemeChoice.mocha;

  ThemeChoice get choice => _choice;

  /// The theme showing now.
  PtTheme get theme => _choice.theme;

  /// Reads the kept choice: Catppuccin Mocha when there's none or it's one
  /// this version doesn't know (0.1.2's `auto` among them).
  void load(SharedPreferences prefs) {
    _prefs = prefs;
    final kept = prefs.getString(prefsKey);
    _choice = ThemeChoice.values.firstWhere((c) => c.name == kept, orElse: () => ThemeChoice.mocha);
    notifyListeners();
  }

  /// Shows [choice] now and keeps it.
  Future<void> choose(ThemeChoice choice) async {
    if (choice == _choice) return;
    _choice = choice;
    notifyListeners();
    await _prefs?.setString(prefsKey, choice.name);
  }
}

/// The app's one [Appearance].
final appearance = Appearance();

/// The active theme's roles, for widgets: `C.accent`. Not constants: the
/// app rebuilds everything under [Themed] when the theme changes, so every
/// read here sees the new one.
abstract final class C {
  static PtTheme get t => appearance.theme;
  static Color get win => t.win;
  static Color get bar => t.bar;
  static Color get field => t.field;
  static Color get sel => t.sel;
  static Color get line => t.line;
  static Color get line2 => t.line2;
  static Color get divider => t.divider;
  static Color get text => t.text;
  static Color get dim => t.dim;
  static Color get dim2 => t.dim2;
  static Color get accent => t.accent;
  static Color get onAccent => t.onAccent;
  static Color get ok => t.ok;
  static Color get warn => t.warn;
  static Color get error => t.error;
  static Color get card => t.card;

  /// Border width of fields, cards and dialogs.
  static double get border => t.shape.border;

  /// [radius] as the theme shapes it: as is when soft, capped when crisp
  /// or boxy.
  static double r(double radius) => radius < t.shape.maxRadius ? radius : t.shape.maxRadius;

  /// Rounded corners of [radius], shaped by the theme ([r]).
  static BorderRadius round(double radius) => BorderRadius.circular(r(radius));

  /// A section or chip label in the theme's case.
  static String label(String text) => t.shape.caps ? text.toUpperCase() : text;
}

/// Builds the app with the active theme, and on every change of it builds
/// every widget under it again, const ones included: they read [C], which
/// no inherited widget tracks. State (pages, fields, scroll) stays.
class Themed extends StatefulWidget {
  const Themed({required this.builder, super.key});
  final Widget Function(BuildContext context, PtTheme theme) builder;

  @override
  State<Themed> createState() => _ThemedState();
}

class _ThemedState extends State<Themed> {
  @override
  void initState() {
    super.initState();
    appearance.addListener(_changed);
  }

  @override
  void dispose() {
    appearance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    void rebuild(Element e) => e
      ..markNeedsBuild()
      ..visitChildren(rebuild);

    (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, appearance.theme);
}
