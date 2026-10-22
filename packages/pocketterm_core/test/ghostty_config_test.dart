@Tags(['posix'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/ghostty_config.dart';

void main() {
  late Directory dir;
  late String xdg;
  late String support;
  late GhosttyConfig config;

  setUp(() {
    dir = Directory(Directory.systemTemp.createTempSync('pocketterm-ghostty-').resolveSymbolicLinksSync());
    xdg = '${dir.path}/.config/ghostty/config.ghostty';
    support = '${dir.path}/Library/Application Support/com.mitchellh.ghostty/config.ghostty';
    config = GhosttyConfig.standard(home: dir.path);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const tmux = '/opt/homebrew/bin/tmux';
  final ours = '${GhosttyConfig.marker}\n${GhosttyConfig.line(tmux)}\n';

  test('with no config anywhere, creates the XDG one with just its lines', () {
    expect(config.read().state, GhosttyCommandState.none);
    expect(config.add(tmux), xdg);
    expect(File(xdg).readAsStringSync(), ours);
    expect(config.read(), (state: GhosttyCommandState.ours, command: GhosttyConfig.line(tmux).substring(10)));
  });

  test('the line runs the absolute tmux in a session per window that ends with it and names it in the title', () {
    expect(
      GhosttyConfig.line(tmux),
      r'command = /opt/homebrew/bin/tmux new-session \; set-option destroy-unattached on'
      r" \; set-option set-titles on \; set-option set-titles-string '#T (tmux #S)'",
    );
    expect(GhosttyConfig.line('/Users/a b/tmux'), startsWith("command = '/Users/a b/tmux' new-session"));
  });

  test('writes to the Application Support file when it is the one that exists', () {
    File(support)
      ..createSync(recursive: true)
      ..writeAsStringSync('font-size = 14\n');
    expect(config.add(tmux), support);
    expect(File(support).readAsStringSync(), 'font-size = 14\n$ours');
    expect(File(xdg).existsSync(), isFalse);
  });

  for (final before in ['', 'font-size = 14\ntheme = dark\n', 'font-size = 14', '# just a comment\n\n']) {
    test('remove leaves the file byte-identical to before add: ${before.replaceAll('\n', r'\n')}', () {
      File(xdg)
        ..createSync(recursive: true)
        ..writeAsStringSync(before);
      Process.runSync('/bin/chmod', ['600', xdg]);
      config.add(tmux);
      expect(File(xdg).readAsStringSync(), startsWith(before));
      expect(config.read().state, GhosttyCommandState.ours);
      expect(File(xdg).statSync().mode & 0x1ff, 0x180, reason: 'permissions kept');
      config.remove();
      expect(File(xdg).readAsStringSync(), before);
      expect(config.read().state, GhosttyCommandState.none);
      expect(File(xdg).statSync().mode & 0x1ff, 0x180, reason: 'permissions kept');
    });
  }

  test('remove takes only the marked lines, wherever they are, even after edits around them', () {
    File(xdg)
      ..createSync(recursive: true)
      ..writeAsStringSync('a = 1\n');
    config.add(tmux);
    File(xdg).writeAsStringSync('${File(xdg).readAsStringSync()}b = 2\n');
    config.remove();
    expect(File(xdg).readAsStringSync(), 'a = 1\nb = 2\n');
  });

  test("a command of the person's own blocks adding, in any file Ghostty reads", () {
    for (final line in ['command = /bin/zsh -l', 'command=fish', '  command  =  "nu"  ']) {
      File(support)
        ..createSync(recursive: true)
        ..writeAsStringSync('# command = ignored\nfont-size = 14\n$line\n');
      final before = File(support).readAsStringSync();
      expect(config.read().state, GhosttyCommandState.theirs, reason: line);
      expect(config.add(tmux), isNull);
      expect(File(support).readAsStringSync(), before);
      expect(File(xdg).existsSync(), isFalse);
    }
    expect(config.read().command, 'nu');
  });

  test('a commented-out or emptied command is not one', () {
    File(xdg)
      ..createSync(recursive: true)
      ..writeAsStringSync('# command = /bin/zsh\ncommand =\n');
    expect(config.read().state, GhosttyCommandState.none);
  });

  test('a hand edit to our line still reads as ours, and Remove takes it', () {
    File(xdg)
      ..createSync(recursive: true)
      ..writeAsStringSync('${GhosttyConfig.marker}\ncommand = /usr/local/bin/tmux new-session\n');
    expect(config.read(), (state: GhosttyCommandState.ours, command: '/usr/local/bin/tmux new-session'));
    config.remove();
    expect(File(xdg).readAsStringSync(), '');
  });

  test("Remove takes the line an earlier PocketTerm wrote (without tmux's titles) too", () {
    File(xdg)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'a = 1\n${GhosttyConfig.marker}\n'
        'command = /opt/homebrew/bin/tmux new-session \\; set-option destroy-unattached on\n',
      );
    expect(config.read().state, GhosttyCommandState.ours);
    config.remove();
    expect(File(xdg).readAsStringSync(), 'a = 1\n');
  });

  group('upgrade', () {
    const old = r'command = /opt/homebrew/bin/tmux new-session \; set-option destroy-unattached on';

    test("an earlier PocketTerm's line becomes this one's; every other byte and the permissions stay", () {
      // Around it: the person's lines, a CRLF one, and no newline at the end.
      const before = 'font-size = 14\r\n# a comment\n${GhosttyConfig.marker}\n$old\ntheme = dark';
      File(xdg)
        ..createSync(recursive: true)
        ..writeAsStringSync(before);
      Process.runSync('/bin/chmod', ['600', xdg]);
      expect(config.upgrade(tmux), isTrue);
      expect(File(xdg).readAsStringSync(), before.replaceFirst(old, GhosttyConfig.line(tmux)));
      expect(File(xdg).statSync().mode & 0x1ff, 0x180, reason: 'permissions kept');
      expect(config.upgrade(tmux), isFalse, reason: 'once');
      config.remove();
      expect(File(xdg).readAsStringSync(), 'font-size = 14\r\n# a comment\ntheme = dark');
    });

    test("a command of the person's own is never touched, PocketTerm's block or not", () {
      const mine = '# command = /bin/zsh\n$old\n';
      File(support)
        ..createSync(recursive: true)
        ..writeAsStringSync(mine);
      File(xdg)
        ..createSync(recursive: true)
        ..writeAsStringSync('${GhosttyConfig.marker}\ncommand =\n');
      expect(config.upgrade(tmux), isFalse);
      expect(File(support).readAsStringSync(), mine);
      expect(File(xdg).readAsStringSync(), '${GhosttyConfig.marker}\ncommand =\n');
    });
  });

  test('writes through a symlinked config to its target', () {
    final real = File('${dir.path}/dotfiles/ghostty')
      ..createSync(recursive: true)
      ..writeAsStringSync('a = 1\n');
    Directory('${dir.path}/.config/ghostty').createSync(recursive: true);
    Link(xdg).createSync(real.path);
    config.add(tmux);
    expect(FileSystemEntity.isLinkSync(xdg), isTrue);
    expect(real.readAsStringSync(), 'a = 1\n$ours');
    config.remove();
    expect(real.readAsStringSync(), 'a = 1\n');
  });
}
