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
}
