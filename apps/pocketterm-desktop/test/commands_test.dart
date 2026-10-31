import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_desktop/commands.dart';

void main() {
  test('a PC without winget gets a failed install that says so, not an exception', () async {
    final pc = Commands(
      windows: true,
      brew: () => null,
      macPorts: () => null,
      run: (exe, args, env) => throw ProcessException(exe, args, 'The system cannot find the file specified.', 2),
    );
    final result = await pc.run(['winget', 'install', '--id', 'Tailscale.Tailscale']);
    expect(result.code, isNot(0));
    expect(result.output, contains('winget'));
  });

  // The script is made executable with /bin/chmod: a Mac's only.
  test("sudo's password script is there while the command runs and gone after, also when it throws", () async {
    final seen = <String>[];
    var fail = false;
    final mac = Commands(
      windows: false,
      brew: () => '/opt/homebrew/bin/brew',
      macPorts: () => null,
      run: (exe, args, env) async {
        final askpass = env['SUDO_ASKPASS']!;
        expect(File(askpass).existsSync(), isTrue);
        seen.add(askpass);
        if (fail) throw ProcessException(exe, args, 'gone', 2);
        return (code: 0, output: '');
      },
    );
    await mac.run(['brew', 'install', 'tmux'], password: 'Homebrew needs your password');
    fail = true;
    await expectLater(mac.run(['brew', 'install', 'tmux'], password: 'again'), throwsA(isA<ProcessException>()));
    expect(seen, hasLength(2));
    for (final path in seen) {
      expect(File(path).parent.existsSync(), isFalse);
    }
  }, tags: 'posix');
}
