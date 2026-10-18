// Symlinks and paths joined with `/`.
@Tags(['posix'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_desktop/integrations.dart';

import 'app_fakes.dart';

/// The files under [dir], by their path below it, hidden ones left out.
Map<String, String> filesIn(String dir) => {
  for (final f in Directory(dir).listSync(recursive: true).whereType<File>())
    if (!f.uri.pathSegments.last.startsWith('.')) f.path.substring(dir.length + 1): f.readAsStringSync(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String home;

  setUp(() => home = Directory.systemTemp.createTempSync('pocketterm-integrations').path);
  tearDown(() => Directory(home).deleteSync(recursive: true));

  group('omp', () {
    test('installs the extension, and tells an outdated copy from a current one', () async {
      final integrations = Integrations(home: home);
      expect(await integrations.state(Agent.omp), (installed: false, current: false, problem: null));

      await integrations.install(Agent.omp);
      final dir = '$home/.omp/agent/extensions';
      expect(filesIn(dir), filesIn('integrations/omp'));
      expect(filesIn(dir).keys, ['pocketterm-live.ts']);
      expect(await integrations.state(Agent.omp), (installed: true, current: true, problem: null));

      File('$dir/pocketterm-live.ts').writeAsStringSync('// older');
      expect(await integrations.state(Agent.omp), (installed: true, current: false, problem: null));

      File('$dir/pocketterm-live.ts').deleteSync();
      expect((await integrations.state(Agent.omp)).installed, isFalse);
    });

    test('replaces a symlinked extension instead of writing through it', () async {
      final dir = Directory('$home/.omp/agent/extensions')..createSync(recursive: true);
      final source = File('$home/checkout-live.ts')..writeAsStringSync('// my checkout');
      Link('${dir.path}/pocketterm-live.ts').createSync(source.path);

      await Integrations(home: home).install(Agent.omp);
      expect(source.readAsStringSync(), '// my checkout');
      expect(FileSystemEntity.isLinkSync('${dir.path}/pocketterm-live.ts'), isFalse);
      expect(
        File('${dir.path}/pocketterm-live.ts').readAsStringSync(),
        File('integrations/omp/pocketterm-live.ts').readAsStringSync(),
      );
    });
  });

  group('Claude Code', () {
    late FakeClaude claude;
    late Integrations integrations;
    late String dir;

    setUp(() {
      claude = FakeClaude('$home/bin/claude');
      File(claude.path).createSync(recursive: true);
      integrations = Integrations(home: home, run: claude.run, claudePaths: ['$home/nope/claude', claude.path]);
      dir = '$home/.config/pocketterm/claude-plugin';
    });

    Map<String, Object?> listed({required String from, bool enabled = true}) => {
      'id': 'pocketterm@pocketterm',
      'enabled': enabled,
      'readFromFolder': '$from/plugins/pocketterm',
    };

    test('a first install copies the marketplace without its tests, adds it and installs the plugin', () async {
      File('$dir/plugins/pocketterm/hooks/gone.ts').createSync(recursive: true);

      await integrations.install(Agent.claude);
      final expected = filesIn('integrations/claude')..removeWhere((f, _) => f.startsWith('plugins/pocketterm/tests/'));
      expect(filesIn(dir), expected);
      expect(
        File('$dir/.claude-plugin/marketplace.json').readAsStringSync(),
        File('integrations/claude/.claude-plugin/marketplace.json').readAsStringSync(),
      );
      expect(File('$dir/plugins/pocketterm/.claude-plugin/plugin.json').existsSync(), isTrue);
      expect(Directory('$dir/plugins/pocketterm/tests').existsSync(), isFalse);
      expect(claude.calls, [
        '--version',
        'plugin list --json',
        'plugin marketplace add $dir --json',
        'plugin install pocketterm@pocketterm --json',
      ]);

      claude.list = [listed(from: dir)];
      expect(await integrations.state(Agent.claude), (installed: true, current: true, problem: null));
      File('$dir/plugins/pocketterm/hooks/hooks.json').writeAsStringSync('{}');
      expect(await integrations.state(Agent.claude), (installed: true, current: false, problem: null));
    });

    test('updating refreshes the marketplace and the plugin, and turns a disabled one back on', () async {
      claude.list = [listed(from: dir, enabled: false)];
      expect((await integrations.state(Agent.claude)).installed, isFalse);
      claude.calls.clear();

      await integrations.install(Agent.claude);
      expect(claude.calls, [
        '--version',
        'plugin list --json',
        'plugin marketplace update pocketterm --json',
        'plugin update pocketterm@pocketterm --json',
        'plugin enable pocketterm@pocketterm --json',
      ]);
    });

    test('a pocketterm plugin loading from elsewhere is moved over to the copy', () async {
      claude.list = [listed(from: '$home/Dev/pocketterm/apps/pocketterm-desktop/integrations/claude')];
      expect((await integrations.state(Agent.claude)).installed, isFalse);
      claude.calls.clear();

      await integrations.install(Agent.claude);
      expect(claude.calls.skip(2), [
        'plugin marketplace add $dir --json',
        'plugin update pocketterm@pocketterm --json',
      ]);
    });

    test('a missing claude is said plainly, and nothing is run or copied', () async {
      File(claude.path).deleteSync();
      const missing = (installed: false, current: false, problem: "Claude Code isn't installed");
      expect(await integrations.state(Agent.claude), missing);
      await expectLater(
        integrations.install(Agent.claude),
        throwsA(isA<IntegrationException>().having((e) => e.message, 'message', "Claude Code isn't installed")),
      );
      expect(claude.calls, isEmpty);
      expect(Directory(dir).existsSync(), isFalse);
    });

    test("claude found only by the login shell's PATH is used", () async {
      File(claude.path).renameSync('$home/claude');
      final onPath = FakeClaude('$home/claude')..onPath = '$home/claude\n';
      final found = Integrations(home: home, run: onPath.run, claudePaths: [claude.path]);
      expect(await found.state(Agent.claude), (installed: false, current: false, problem: null));
      expect(onPath.calls, ['--version', 'plugin list --json']);
    });

    test("on Windows claude is the native installer's claude.exe, and no login shell is asked", () async {
      final exe = FakeClaude('$home/.local/bin/claude.exe')..onPath = '$home/claude\n';
      File(exe.path).createSync(recursive: true);
      final ran = <String>[];
      final windows = Integrations(
        home: home,
        run: (e, args) {
          ran.add(e);
          return exe.run(e, args);
        },
        windows: true,
      );
      expect(await windows.state(Agent.claude), (installed: false, current: false, problem: null));
      expect(exe.calls, ['--version', 'plugin list --json']);

      File(exe.path).deleteSync();
      expect((await windows.state(Agent.claude)).problem, "Claude Code isn't installed");
      expect(ran, isNot(contains('/bin/zsh')));
    });

    test('a Claude Code older than mods is too old', () async {
      claude.version = '2.1.286 (Claude Code)';
      expect(
        (await integrations.state(Agent.claude)).problem,
        'Claude Code 2.1.286 is too old: update it to 2.1.287 or later',
      );
      claude.version = '2.2.0 (Claude Code)';
      expect((await integrations.state(Agent.claude)).problem, isNull);
    });

    test('mods switched off are noticed through claude plugin test', () async {
      expect(await integrations.claudeModsOff(), isFalse);
      claude.modsOff = true;
      expect(await integrations.claudeModsOff(), isTrue);
      expect(claude.calls.last, startsWith('plugin test '));
      // The empty directory it tests is gone again.
      expect(Directory(claude.calls.last.substring('plugin test '.length)).existsSync(), isFalse);

      File(claude.path).deleteSync();
      expect(await integrations.claudeModsOff(), isFalse);
    });

    test('a failing claude command fails the install with what it said', () async {
      claude.fail = 'plugin install pocketterm@pocketterm --json';
      await expectLater(
        integrations.install(Agent.claude),
        throwsA(isA<IntegrationException>().having((e) => e.message, 'message', 'Plugin "pocketterm" not found')),
      );
    });
  });
}
