// The Mac screenshots in the docs: the real widgets, made-up data, the Mac's own fonts.
// Run from apps/pocketterm-desktop: fvm flutter test --tags screenshots --run-skipped
// They're written to docs/images/mac-settings-*.png, mac-setup-*.png and get-ready.png; a plain `fvm flutter test`
// skips them (dart_test.yaml).
@Tags(['screenshots', 'posix'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/apple_terminal.dart';
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/iterm.dart';
import 'package:pocketterm_core/kitty.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/tmux.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_core/wezterm.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_desktop/live_hub.dart';
import 'package:pocketterm_desktop/main_window.dart';
import 'package:pocketterm_desktop/onboarding/get_ready.dart';
import 'package:pocketterm_desktop/setup_page.dart';
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

/// The first-run setup on [choice]'s screen (the two choices if null), as the main window shows it before there is a
/// server. [tailscale]: what This computer finds.
Future<FakeApp> pumpSetup(WidgetTester tester, {SetupChoice? choice, FakeTailscale? tailscale}) async {
  final app = await FakeApp.create(tailscale: (tailscale ?? FakeTailscale()).tailscale);
  await tester.pumpWidget(
    subject(
      ColoredBox(
        color: C.win,
        child: SetupPage(app: app, choice: choice, poll: Duration.zero),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return app;
}

/// Types [text] into the [index]th text field, then leaves it.
Future<void> fillField(WidgetTester tester, int index, String text) async {
  await tester.enterText(find.byType(TextField).at(index), text);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

/// A Mac's terminals as Settings finds them: by default kitty, macOS's
/// Terminal and tmux, as a typical Mac might have; [found] for others.
/// [shown]: its windows; ten shells by default. `tmuxExe`: tmux's
/// executable, installed when it exists.
class DemoTerminals extends Terminals {
  DemoTerminals({
    this.found,
    this.shown,
    super.home = '/nonexistent-pocketterm-demo',
    String tmuxExe = '/nonexistent-pocketterm-demo/tmux',
  }) : super(
         kitty: Kitty(socketDir: '/nonexistent-pocketterm-demo', home: '/nonexistent-pocketterm-demo'),
         tmux: Tmux(executable: tmuxExe, socketDirs: const []),
         wezterm: WezTerm(
           executable: '/nonexistent-pocketterm-demo/wezterm',
           socketDir: '/nonexistent-pocketterm-demo',
         ),
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
  // Settings at the window's own width, tall enough that no tab scrolls: one picture per tab.
  shot('settings: each tab', const Size(760, 1000), (tester) async {
    final home = Directory.systemTemp.createTempSync('pocketterm-shots').path;
    addTearDown(() => Directory(home).deleteSync(recursive: true));
    PackageInfo.setMockInitialValues(
      appName: 'PocketTerm',
      packageName: 'com.danyzmaj.pocketterm',
      version: '0.1.0',
      buildNumber: '6',
      buildSignature: '',
    );
    // Claude Code has an older PocketTerm than this app's.
    final claude = FakeClaude('$home/bin/claude')
      ..list = [
        {
          'id': 'pocketterm@pocketterm',
          'enabled': true,
          'readFromFolder': '$home/.config/pocketterm/claude-plugin/plugins/pocketterm',
        },
      ];
    File(claude.path).createSync(recursive: true);
    final integrations = Integrations(home: home, run: claude.run, claudePaths: [claude.path], ompPaths: const []);
    await tester.runAsync(() => integrations.install(Agent.omp));
    const demo = '/nonexistent-pocketterm-demo';
    final app =
        await FakeApp.create(
            terminals: DemoTerminals(
              // An installed tmux, for Ghostty's Start new windows in tmux.
              tmuxExe: '/bin/sh',
              found: (t) => [
                TermStatus(t.kitty!.id, t.kitty!.label, TermState.ready, note: '10 windows'),
                TermStatus(t.tmux!.id, t.tmux!.label, TermState.ready, note: '2 panes'),
                TermStatus(t.wezterm!.id, t.wezterm!.label, TermState.missing),
                TermStatus(t.iterm!.id, t.iterm!.label, TermState.idle),
                TermStatus(
                  t.terminal!.id,
                  t.terminal!.label,
                  TermState.ready,
                  note:
                      'Sessions from your phone run in tmux, with full control. '
                      'In windows you open yourself: ${t.terminal!.limits}',
                ),
                TermStatus(
                  t.ghostty!.id,
                  t.ghostty!.label,
                  TermState.ready,
                  note:
                      '2 windows · Sessions from your phone run in tmux, with full control. '
                      'In windows you open yourself: ${t.ghostty!.limits}',
                ),
              ],
              // Ten shells, and two omp sessions opened before PocketTerm.
              shown: [
                for (var i = 0; i < 8; i++) TermWindow(key: 'kitty-1/$i', title: '', tab: '', cwd: '', program: ''),
                const TermWindow(key: 'kitty-1/8', title: 'omp', tab: '', cwd: '$demo/Dev/garden-api', program: 'omp'),
                const TermWindow(key: 'kitty-1/9', title: 'omp', tab: '', cwd: '$demo/Dev/shop-web', program: 'omp'),
              ],
            ),
            integrations: integrations,
            // This Mac runs the server, which Tailscale publishes.
            tailscale: FakeTailscale(installed: true, dnsName: 'ana-macbook.tail4b2c.ts.net').tailscale,
            serverDir: Directory('$home/server'),
          )
          ..name = 'Ana'
          ..phoneUsedCode = true
          ..devices = const [
            Device(id: 'd1', role: DeviceRole.desktop, label: 'Ana’s MacBook', platform: 'macos'),
            Device(id: 'd2', role: DeviceRole.desktop, label: 'Mac mini', platform: 'macos'),
            Device(id: 'p1', role: DeviceRole.phone, label: 'iPhone', platform: 'ios'),
          ];
    await tester.runAsync(app.startHosting);
    await tester.runAsync(() => app.hosting!.refresh());
    app.host.loginItem = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('terminal_bridge', true);
    // DemoTerminals' home, so they read ~/Dev and ~/Projects.
    await app.setProjectRoots(['$demo/Dev', '$demo/Projects']);
    // Two coding agents report to PocketTerm.
    for (final (pid, title) in [(101, 'Retry queue'), (102, 'Dark mode')]) {
      final frames = StreamController<String>();
      addTearDown(frames.close);
      unawaited(app.live.accept(frames.stream, _Link()));
      frames.add(
        '{"t":"hello","v":1,"pid":$pid,"agent":"omp","busy":false,"items":[],'
        '"session":{"id":"s$pid","title":"$title","cwd":"$demo/Dev/garden-api","model":"m"}}',
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
    for (var i = 0; i < 100 && find.textContaining('need attention').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    for (final (tab, name) in [
      ('phone', 'mac-settings-phone.png'),
      ('agents', 'mac-settings-agents.png'),
      ('terminals', 'mac-settings-terminals.png'),
      ('account', 'mac-settings-account.png'),
    ]) {
      await tester.tap(find.byKey(ValueKey('settings-tab-$tab')));
      await tester.pumpAndSettle();
      if (tab == 'agents') {
        await tester.tap(find.text('Show sessions'));
        await tester.pumpAndSettle();
      }
      final view = tester.getRect(find.byKey(_shot));
      final content = tester.getRect(find.byKey(const ValueKey('settings-content')));
      await save(
        tester,
        name,
        crop: Rect.fromLTRB(view.left, view.top, view.right, content.bottom + 22),
        radius: 12,
        border: C.line2,
      );
    }
    await tester.runAsync(() async => await app.hosting?.stop());
  });

  // The first-run setup, made-up values only.
  const setupView = Size(540, 640);
  const card = (radius: 12.0, border: C.line2);

  shot('setup: the two choices', setupView, (tester) async {
    await pumpSetup(tester);
    await save(tester, 'mac-setup.png', radius: card.radius, border: card.border);
  });

  shot('setup: this computer, Tailscale ready', setupView, (tester) async {
    await pumpSetup(tester, choice: SetupChoice.thisComputer, tailscale: FakeTailscale(installed: true));
    await save(tester, 'mac-setup-this-computer.png', radius: card.radius, border: card.border);
  });

  shot('setup: this computer, HTTPS off', setupView, (tester) async {
    await pumpSetup(tester, choice: SetupChoice.thisComputer, tailscale: FakeTailscale(installed: true, https: false));
    await save(tester, 'mac-setup-https-off.png', radius: card.radius, border: card.border);
  });

  shot('setup: your own server', setupView, (tester) async {
    await pumpSetup(tester, choice: SetupChoice.ownServer);
    await fillField(tester, 0, 'pocketterm://setup?url=https%3A%2F%2Fpt.example.com&setup=Xq3v…');
    await save(tester, 'mac-setup-own-server.png', radius: card.radius, border: card.border);
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
        shown: [
          TermWindow(key: 'kitty-1/4', title: 'omp', tab: '', cwd: '$home/Dev/garden-api', program: 'omp'),
          TermWindow(key: 'kitty-1/7', title: 'claude', tab: '', cwd: '$home/Dev/shop-web', program: 'claude'),
        ],
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
      radius: card.radius,
      border: card.border,
    );
  });
}
