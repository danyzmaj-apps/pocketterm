import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_desktop/controller.dart';

import 'app_fakes.dart';

void main() {
  test("kitty's sockets are in /tmp unless POCKETTERM_KITTY_DIR names another directory", () {
    expect(AppController.kittyDir({}), '/tmp');
    expect(AppController.kittyDir({'POCKETTERM_KITTY_DIR': ''}), '/tmp');
    expect(AppController.kittyDir({'POCKETTERM_KITTY_DIR': '/tmp/pocketterm-e2e'}), '/tmp/pocketterm-e2e');
  });

  testWidgets('signed out, nothing goes to the phone, and the computer is not even asked', (tester) async {
    final app = await FakeApp.create();
    app.fakeUser = null;
    expect(await app.notifyPhone('omp finished · app', 'Done.', session: 'kitty:/tmp/k/1'), isFalse);
    expect(app.calls, isEmpty);
  });

  testWidgets("this computer's id is made once per user, in the form the server takes", (tester) async {
    final app = await FakeApp.create();
    final id = app.desktopId('user-1');
    expect(id, matches(RegExp(r'^[a-z0-9]{8}$')));
    expect(app.desktopId('user-1'), id);
    expect(app.desktopId('user-2'), isNot(id));
  });

  test("the computer's name fits the server's 1 to 80 characters", () {
    expect(AppController.desktopName('  Ana’s MacBook  '), 'Ana’s MacBook');
    expect(AppController.desktopName(' '), 'Computer');
    expect(AppController.desktopName('x' * 100), 'x' * 80);
  });
}
