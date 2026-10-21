// The Mac screenshots in the docs: the real widgets, made-up data, the Mac's own fonts.
// Run from apps/pocketterm-desktop: fvm flutter test --tags screenshots --run-skipped
// They're written to docs/images/mac-*.png, wizard-*.png and get-ready.png; a plain `fvm flutter test` skips
// them (dart_test.yaml).
@Tags(['screenshots', 'posix'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/apple_terminal.dart';
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/iterm.dart';
import 'package:pocketterm_core/kitty.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/tmux.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_core/wezterm.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_desktop/live_hub.dart';
import 'package:pocketterm_desktop/main_window.dart';
import 'package:pocketterm_desktop/onboarding/flow.dart';
import 'package:pocketterm_desktop/onboarding/get_ready.dart';
import 'package:pocketterm_desktop/onboarding/provision.dart';
import 'package:pocketterm_desktop/onboarding/wizard.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_fakes.dart';
import 'fonts.dart';

final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);
final _out = Directory('../../docs/images');
final GlobalKey _shot = GlobalKey();

/// A screenshot test: [body] on a Mac, with the view at [size] logical
/// pixels (twice as many physical ones), real fonts and real (blurred)
/// shadows. Skipped without the Mac's fonts.
void shot(String description, Size size, Future<void> Function(WidgetTester tester) body) =>
    testWidgets(description, (tester) async {
      if (missingFont() case final missing?) return markTestSkipped('No $missing on this machine');
      await tester.runAsync(loadRealFonts);
      tester.view
        ..physicalSize = size * 2
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      debugDisableShadows = false;
      try {
        await body(tester);
      } finally {
        debugDisableShadows = true;
      }
    }, variant: _mac);

/// [child] as main.dart hosts a window ([window]), with the glyphs SF Pro
/// lacks (⇥, ↵, emoji) from the fonts macOS falls back to, and painted into
/// [_shot].
Widget subject(Widget child) => window(
  RepaintBoundary(
    key: _shot,
    child: Builder(
      builder: (context) {
        const fallback = ['Apple Symbols', 'Apple Color Emoji'];
        final theme = Theme.of(context);
        // The fields' text comes from the theme, the rest from the default style.
        return Theme(
          data: theme.copyWith(textTheme: theme.textTheme.apply(fontFamilyFallback: fallback)),
          child: DefaultTextStyle.merge(
            style: const TextStyle(fontFamilyFallback: fallback),
            child: child,
          ),
        );
      },
    ),
  ),
);

/// Writes [crop] (global logical pixels; all of [_shot] if null) of what
/// [_shot] paints to docs/images/[name], rounded by [radius] and outlined
/// in [border] if given.
Future<void> save(WidgetTester tester, String name, {Rect? crop, double radius = 0, Color? border}) async {
  final box = tester.getRect(find.byKey(_shot));
  final r = (crop ?? box).intersect(box).shift(-box.topLeft);
  await tester.runAsync(() async {
    final boundary = _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final full = await boundary.toImage(pixelRatio: 2);
    final src = Rect.fromLTRB(r.left * 2, r.top * 2, r.right * 2, r.bottom * 2);
    final (w, h) = (src.width.round(), src.height.round());
    final dst = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final shape = RRect.fromRectAndRadius(dst, Radius.circular(radius * 2));
    if (radius > 0) canvas.clipRRect(shape);
    canvas.drawImageRect(full, src, dst, Paint()..filterQuality = FilterQuality.none);
    if (border != null) {
      canvas.drawRRect(
        shape.deflate(1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = border,
      );
    }
    final image = await recorder.endRecording().toImage(w, h);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final to = _out..createSync(recursive: true);
    File('${to.path}/$name').writeAsBytesSync(png!.buffer.asUint8List());
  });
}

/// The setup wizard at [flow]'s step, as the main window shows it before
/// there is a server.
Future<void> pumpWizard(WidgetTester tester, SetupFlow flow) async {
  addTearDown(flow.dispose);
  await tester.pumpWidget(
    subject(
      ColoredBox(
        color: C.win,
        child: SetupWizard(flow: flow, onConnect: (_) async {}, onExisting: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Types [text] into the [index]th text field, then leaves it.
Future<void> fillField(WidgetTester tester, int index, String text) async {
  await tester.enterText(find.byType(TextField).at(index), text);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

/// A Mac's terminals as Settings finds them: by default kitty, macOS's
/// Terminal and tmux, as a typical Mac might have; [found] for others.
/// [shown]: its windows; ten shells by default.
class DemoTerminals extends Terminals {
  DemoTerminals({this.found, this.shown, super.home = '/nonexistent-pocketterm-demo'})
    : super(
        kitty: Kitty(socketDir: '/nonexistent-pocketterm-demo', home: '/nonexistent-pocketterm-demo'),
        tmux: Tmux(executable: '/nonexistent-pocketterm-demo/tmux', socketDirs: const []),
        wezterm: WezTerm(executable: '/nonexistent-pocketterm-demo/wezterm', socketDir: '/nonexistent-pocketterm-demo'),
        iterm: ITerm(appPath: '/nonexistent-pocketterm-demo/iTerm.app'),
        terminal: AppleTerminal(appPath: '/nonexistent-pocketterm-demo/Terminal.app'),
        ghostty: Ghostty(appPath: '/nonexistent-pocketterm-demo/Ghostty.app'),
        recency: () async => const [],
        snapshot: () async => Procs(const []),
      );

  final List<TermStatus> Function(DemoTerminals t)? found;
  final List<TermWindow>? shown;

  @override
  Future<List<TermStatus>> statuses() async =>
      found?.call(this) ??
      [
        TermStatus(kitty!.id, kitty!.label, TermState.ready, note: '3 windows'),
        TermStatus(tmux!.id, tmux!.label, TermState.ready, note: '2 panes'),
        TermStatus(wezterm!.id, wezterm!.label, TermState.missing),
        TermStatus(iterm!.id, iterm!.label, TermState.missing),
        TermStatus(terminal!.id, terminal!.label, TermState.limited, note: '1 window · ${terminal!.limits}'),
        TermStatus(ghostty!.id, ghostty!.label, TermState.missing),
      ];

  @override
  Future<List<TermWindow>> windows() async =>
      shown ?? [for (var i = 0; i < 10; i++) TermWindow(key: 'demo:$i', title: '', tab: '', cwd: '', program: '')];
}

/// The setup checklist's Mac: kitty not set up yet, tmux, Terminal and Ghostty.
List<TermStatus> _kittyToSetUp(DemoTerminals t) => [
  TermStatus(
    t.kitty!.id,
    t.kitty!.label,
    TermState.setup,
    note: "kitty doesn't let PocketTerm in yet",
    fix: TermFix.kittyConfig,
  ),
  TermStatus(t.tmux!.id, t.tmux!.label, TermState.ready, note: '1 pane'),
  TermStatus(t.wezterm!.id, t.wezterm!.label, TermState.missing),
  TermStatus(t.iterm!.id, t.iterm!.label, TermState.missing),
  TermStatus(t.terminal!.id, t.terminal!.label, TermState.limited, note: '1 window · ${t.terminal!.limits}'),
  TermStatus(t.ghostty!.id, t.ghostty!.label, TermState.idle),
];

/// A coding agent's extension connection that goes nowhere.
class _Link implements LiveLink {
  @override
  void send(String frame) {}

  @override
  Future<void> close() async {}
}

void main() {
  // Tall enough that Settings doesn't scroll.
  shot('settings: terminals', const Size(560, 2000), (tester) async {
    final home = Directory.systemTemp.createTempSync('pocketterm-shots').path;
    addTearDown(() => Directory(home).deleteSync(recursive: true));
    final integrations = Integrations(
      home: home,
      run: (_, _) async => ProcessResult(0, 1, '', ''),
      claudePaths: const [],
      ompPaths: const [],
    );
    await tester.runAsync(() => integrations.install(Agent.omp));
    final app = await FakeApp.create(terminals: DemoTerminals(), integrations: integrations)
      ..name = 'Ana';
    await (await SharedPreferences.getInstance()).setBool('terminal_bridge', true);
    // DemoTerminals' home, so it reads ~/Dev.
    await app.setProjectRoots(['/nonexistent-pocketterm-demo/Dev']);
    // Two coding agents report to PocketTerm.
    for (final (pid, title) in [(101, 'Retry queue'), (102, 'Dark mode')]) {
      final frames = StreamController<String>();
      addTearDown(frames.close);
      unawaited(app.live.accept(frames.stream, _Link()));
      frames.add(
        '{"t":"hello","v":1,"pid":$pid,"agent":"omp","busy":false,"items":[],'
        '"session":{"id":"s$pid","title":"$title","cwd":"/Users/demo/Dev/garden-api","model":"m"}}',
      );
    }
    await tester.pumpWidget(
      subject(
        ColoredBox(
          color: C.win,
          child: ListenableBuilder(
            listenable: app,
            builder: (_, _) => SettingsPage(app: app),
          ),
        ),
      ),
    );
    for (var i = 0; i < 100 && find.text('Installed and up to date').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final page = tester.getRect(find.byWidgetPredicate((w) => w is ConstrainedBox && w.constraints.maxWidth == 500));
    final top = tester.getRect(find.text('GENERAL')).top - 16;
    await save(
      tester,
      'mac-settings-terminals.png',
      crop: Rect.fromLTRB(page.left - 24, top, page.right + 24, page.bottom + 20),
      radius: 12,
      border: C.line2,
    );
  });

  // The setup wizard, made-up values only: no account, token or project is real.
  const wizardView = Size(540, 620);
  const wizardCard = (radius: 12.0, border: C.line2);

  shot('wizard: token', wizardView, (tester) async {
    await pumpWizard(tester, SetupFlow()..step = WizardStep.token);
    await fillField(tester, 0, 'sbp_demo0000000000000000000000000000000000');
    await save(tester, 'wizard-token.png', radius: wizardCard.radius, border: wizardCard.border);
  });

  shot('wizard: github', wizardView, (tester) async {
    await pumpWizard(
      tester,
      SetupFlow()
        ..step = WizardStep.github
        ..ref = 'demoprojectrefabcdef',
    );
    await fillField(tester, 0, 'Ov23liDemo0000000000');
    await fillField(tester, 1, 'demo0000000000000000000000000000000000000');
    await save(tester, 'wizard-github.png', radius: wizardCard.radius, border: wizardCard.border);
  });

  shot('wizard: ready', wizardView, (tester) async {
    final flow = SetupFlow()
      ..step = WizardStep.setup
      ..ready = true;
    flow.done.addAll(ProvisionStep.values);
    await pumpWizard(tester, flow);
    await save(tester, 'wizard-ready.png', radius: wizardCard.radius, border: wizardCard.border);
  });

  shot('get ready: a Mac after the first sign-in', const Size(560, 1700), (tester) async {
    final home = Directory.systemTemp.createTempSync('pocketterm-shots').resolveSymbolicLinksSync();
    addTearDown(() => Directory(home).deleteSync(recursive: true));
    for (final d in ['Dev', 'Projects', 'Documents']) {
      Directory('$home/$d').createSync();
    }
    final integrations = Integrations(
      home: home,
      run: (_, _) async => ProcessResult(0, 1, '', ''),
      claudePaths: const [],
      ompPaths: const [],
    );
    await tester.runAsync(() => integrations.install(Agent.omp));
    final app = await FakeApp.create(
      terminals: DemoTerminals(
        home: home,
        found: _kittyToSetUp,
        shown: [TermWindow(key: 'kitty-1/4', title: 'omp', tab: '', cwd: '$home/Dev/garden-api', program: 'omp')],
      ),
      integrations: integrations,
    );
    await tester.pumpWidget(
      subject(
        ColoredBox(
          color: C.win,
          child: ListenableBuilder(
            listenable: app,
            builder: (_, _) => GetReadyPage(app: app),
          ),
        ),
      ),
    );
    for (var i = 0; i < 100 && find.text('PocketTerm is installed in omp').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final page = tester.getRect(find.byWidgetPredicate((w) => w is ConstrainedBox && w.constraints.maxWidth == 500));
    await save(
      tester,
      'get-ready.png',
      crop: Rect.fromLTRB(page.left - 24, page.top - 24, page.right + 24, page.bottom + 24),
      radius: wizardCard.radius,
      border: wizardCard.border,
    );
  });

  shot('settings: status card', const Size(560, 2000), (tester) async {
    final home = Directory.systemTemp.createTempSync('pocketterm-shots').path;
    addTearDown(() => Directory(home).deleteSync(recursive: true));
    final integrations = Integrations(
      home: home,
      run: (_, _) async => ProcessResult(0, 1, '', ''),
      claudePaths: const [],
      ompPaths: const [],
    );
    // omp was used here, PocketTerm isn't in it yet.
    Directory('$home/.omp').createSync();
    final app =
        await FakeApp.create(
            terminals: DemoTerminals(found: _kittyToSetUp),
            integrations: integrations,
          )
          ..name = 'Ana';
    await tester.pumpWidget(
      subject(
        ColoredBox(
          color: C.win,
          child: ListenableBuilder(
            listenable: app,
            builder: (_, _) => SettingsPage(app: app),
          ),
        ),
      ),
    );
    for (var i = 0; i < 100 && find.textContaining('need attention').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byKey(const ValueKey('settings-status')));
    await save(
      tester,
      'mac-settings-status.png',
      crop: Rect.fromLTRB(card.left - 24, card.top - 20, card.right + 24, card.bottom + 20),
      radius: 12,
      border: C.line2,
    );
  });
}
