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
}
