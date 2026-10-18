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
}
