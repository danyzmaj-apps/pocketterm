@Tags(['posix'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/tmux.dart';

/// Real tmux servers of their own (`-S` in a temp folder, no tmux.conf),
/// never the person's: [Tmux] is given only that folder.
void main() {
  final exe = findExecutable('tmux');
  late Directory dir;
  final servers = <String>[];

  setUp(() => dir = Directory('/tmp').createTempSync('ptm'));
  tearDown(() {
    for (final s in servers) {
      Process.runSync(exe!, ['-S', s, 'kill-server']);
    }
    servers.clear();
    dir.deleteSync(recursive: true);
  });

  /// A server on socket [name] in [dir] (or [at]) with one pane running
  /// [command] in [cwd]; the socket's path.
  String server(String name, List<String> command, {String? cwd, String? at}) {
    final socket = '${at ?? dir.path}/$name';
    final r = Process.runSync(exe!, [
      '-S',
      socket,
      '-f',
      '/dev/null',
      'new-session',
      '-d',
      '-x',
      '120',
      '-y',
      '30',
      '-c',
      cwd ?? dir.path,
      ...command,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    servers.add(socket);
    return socket;
  }

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  group('a real tmux', skip: exe == null ? 'tmux is not installed' : null, () {
    test('a pane in a folder whose name holds a tab and a line break is listed, with that folder', () async {
      final weird = Directory('${dir.path}/tab\there\nnew line')..createSync();
      server('edge', ['sleep', '60'], cwd: weird.path);
      final panes = await Tmux(socketDirs: [dir.path]).windows(Procs(const []));
      expect(panes.map((w) => w.cwd), [weird.resolveSymbolicLinksSync()]);
    });

    test('text over the 16 KB tmux takes in one command arrives whole and in order', () async {
      final text = List.generate(3000, (i) => 'é漢👍"\'\$x$i ').join();
      final bytes = utf8.encode(text).length;
      expect(bytes, greaterThan(40000));
      final out = File('${dir.path}/out');
      server('edge', ['/bin/sh', '-c', 'stty raw -echo; head -c $bytes > ${out.path}']);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final tmux = Tmux(socketDirs: [dir.path]);
      final key = (await tmux.windows(Procs(const []))).single.key;
      await tmux.type(key, text);
      await until(() => out.existsSync() && out.lengthSync() >= bytes);
      expect(out.readAsStringSync(), text);
    });

    test("a killed server's panes read as gone, its socket left behind", () async {
      final socket = server('edge', ['sleep', '60']);
      final tmux = Tmux(socketDirs: [dir.path]);
      final key = (await tmux.windows(Procs(const []))).single.key;
      final pid = int.parse('${Process.runSync(exe!, ['-S', socket, 'display', '-p', '#{pid}']).stdout}'.trim());
      Process.killPid(pid, ProcessSignal.sigkill);
      await until(() => Process.runSync('/bin/kill', ['-0', '$pid']).exitCode != 0);
      expect(FileSystemEntity.typeSync(socket), FileSystemEntityType.unixDomainSock);
      expect(await tmux.windows(Procs(const [])), isEmpty);
      await expectLater(tmux.type(key, 'x'), throwsA(_gone));
    });

    test('a server an agent named, outside the folders looked in, is gone once its socket is', () async {
      final elsewhere = Directory('/tmp').createTempSync('ptm');
      addTearDown(() => elsewhere.deleteSync(recursive: true));
      final socket = server('agent', ['sleep', '60'], at: elsewhere.path);
      final tmux = Tmux(socketDirs: [dir.path])..learn(socket);
      final key = (await tmux.windows(Procs(const []))).single.key;
      expect(key, startsWith('tmux:agent/'));
      Process.runSync(exe!, ['-S', socket, 'kill-server']);
      File(socket).deleteSync();
      expect(await tmux.windows(Procs(const [])), isEmpty);
      await expectLater(tmux.type(key, 'x'), throwsA(_gone));
    });

    group('when PocketTerm has no locale (started from Finder or the Dock)', () {
      /// tmux as such an app runs it: without the LANG and LC_ALL of the
      /// terminal these tests run in (LC_CTYPE only as PocketTerm hands it
      /// over), its default server in [dir].
      String noLocaleTmux() {
        final wrapper = File('${dir.path}/tmux-no-locale')
          ..writeAsStringSync('#!/bin/sh\nexport TMUX_TMPDIR=${dir.path}\nunset LANG LC_ALL\nexec $exe "\$@"\n');
        Process.runSync('/bin/chmod', ['+x', wrapper.path]);
        return wrapper.path;
      }

      test("a pane in a folder named in other letters is listed with that folder, not with _'s", () async {
        final named = Directory('${dir.path}/Projekt čćž 日本')..createSync();
        server('edge', ['sleep', '60'], cwd: named.path);
        final panes = await Tmux(
          executable: noLocaleTmux(),
          socketDirs: [dir.path],
          env: const {},
        ).windows(Procs(const []));
        expect(panes.map((w) => w.cwd), [named.resolveSymbolicLinksSync()]);
      });

      test('the shells of a server it starts have a UTF-8 locale', () async {
        final out = File('${dir.path}/locale');
        final tmux = Tmux(executable: noLocaleTmux(), socketDirs: [dir.path], env: const {});
        await tmux.launch(dir.path, command: ['/bin/sh', '-c', 'locale > ${out.path}; sleep 60']);
        servers.add(Process.runSync(noLocaleTmux(), ['display', '-p', '#{socket_path}']).stdout.toString().trim());
        await until(() => out.existsSync() && out.lengthSync() > 0);
        expect(out.readAsStringSync(), contains('LC_CTYPE="UTF-8"'));
      });
    });
  });

  group('a tmux that misbehaves', () {
    /// A tmux that runs [script], and a socket for it to be asked on.
    Future<Tmux> fake(String script, {Duration timeout = const Duration(seconds: 5)}) async {
      final exe = File('${dir.path}/tmux')..writeAsStringSync('#!/bin/sh\n$script\n');
      Process.runSync('/bin/chmod', ['+x', exe.path]);
      final server = await ServerSocket.bind(InternetAddress('${dir.path}/fake', type: InternetAddressType.unix), 0);
      addTearDown(server.close);
      return Tmux(executable: exe.path, socketDirs: [dir.path], timeout: timeout);
    }

    test("output that isn't UTF-8 reads with U+FFFD instead of failing", () async {
      final tmux = await fake(r"printf 'a\377\376b'");
      expect(await tmux.plainScreen('tmux:fake/0'), 'a\uFFFD\uFFFDb');
    });

    test('a tmux that never answers is killed, not left behind', () async {
      final pidFile = '${dir.path}/pid';
      final tmux = await fake('echo \$\$ > $pidFile; exec sleep 30', timeout: const Duration(seconds: 2));
      await expectLater(
        tmux.type('tmux:fake/0', 'x'),
        throwsA(isA<TerminalException>().having((e) => e.message, 'message', 'tmux did not answer.')),
      );
      // Under load the shell may not have started yet; then nothing runs anyway.
      if (!File(pidFile).existsSync()) return;
      final pid = File(pidFile).readAsStringSync().trim();
      await until(() => Process.runSync('/bin/kill', ['-0', pid]).exitCode != 0);
      expect(Process.runSync('/bin/kill', ['-0', pid]).exitCode, isNot(0), reason: 'tmux $pid still runs');
    });
  });
}

final Matcher _gone = isA<TerminalException>().having((e) => e.message, 'message', 'That window is gone.');
