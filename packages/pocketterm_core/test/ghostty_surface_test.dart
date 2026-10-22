import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/terminal.dart';

Proc _p(int pid, int ppid, String tty, String args) =>
    Proc(pid: pid, ppid: ppid, pgid: pid, tpgid: pid, tty: tty, stat: 'Ss', args: args);

void main() {
  const ghostty = 100;
  final base = [
    _p(100, 1, '', '/Applications/Ghostty.app/Contents/MacOS/ghostty'),
    _p(200, 1, '', '/Applications/kitty.app/Contents/MacOS/kitty'),
  ];

  test("Ghostty 1.3's double-forked surfaces count: login or a login command whose parent is gone", () {
    final procs = Procs([
      ...base,
      _p(301, 300, 'ttys014', '/usr/bin/login -flp me /bin/bash --noprofile --norc -c exec -l /bin/zsh'),
      _p(302, 301, 'ttys014', '-zsh'),
      _p(311, 310, 'ttys015', '-/bin/sleep 79'),
      _p(321, ghostty, 'ttys016', '/usr/bin/login -flp me'),
    ]);
    expect(ghosttySurfaceTtys(procs, ghostty), {'ttys014', 'ttys015', 'ttys016'});
  });

  test("another terminal's shells and orphans that aren't a surface root stay out", () {
    final procs = Procs([
      ...base,
      // kitty's shell: its parent is there.
      _p(401, 200, 'ttys020', '-zsh'),
      // An orphan that isn't a login or a login command (nohup'd job).
      _p(411, 410, 'ttys021', 'python3 server.py'),
      // Reparented to launchd.
      _p(421, 1, 'ttys022', '-zsh'),
    ]);
    expect(ghosttySurfaceTtys(procs, ghostty), isEmpty);
    expect(ghosttySurfaceTtys(procs, null), isEmpty);
  });

  group('the tty of a window PocketTerm opened', () {
    late Directory tmp;
    late String mine;
    late String other;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ghostty-launch');
      mine = (Directory('${tmp.path}/mine')..createSync()).resolveSymbolicLinksSync();
      other = (Directory('${tmp.path}/other')..createSync()).resolveSymbolicLinksSync();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    final procs = Procs([
      ...base,
      _p(501, 500, 'ttys030', '-zsh'),
      _p(502, 501, 'ttys030', 'omp'),
      _p(511, 510, 'ttys031', '-zsh'),
    ]);

    test('another window starting at the same time: the one in its folder', () {
      final cwds = {501: other, 502: other, 511: mine};
      // Asked by the path it was given (/tmp is /private/tmp on a Mac).
      expect(ghosttyNewTty({'ttys030', 'ttys031'}, procs, cwds, '${tmp.path}/mine'), 'ttys031');
      expect(ghosttyNewTty({'ttys030', 'ttys031'}, procs, cwds, other), 'ttys030');
    });

    test("the other window's terminal coming up first isn't taken for this one", () {
      expect(ghosttyNewTty({'ttys030'}, procs, {501: other, 502: other}, mine), isNull);
    });

    test('two in the same folder are not told apart; with no folders known, only one new counts', () {
      expect(ghosttyNewTty({'ttys030', 'ttys031'}, procs, {501: mine, 511: mine}, mine), isNull);
      expect(ghosttyNewTty({'ttys031'}, procs, const {}, mine), 'ttys031');
      expect(ghosttyNewTty({'ttys030', 'ttys031'}, procs, const {}, mine), isNull);
    });
  });
}
