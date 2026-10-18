import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_desktop/controller.dart';

import 'app_fakes.dart';

void main() {
  test("kitty's sockets are in /tmp unless POCKETTERM_KITTY_DIR names another directory", () {
    expect(AppController.kittyDir({}), '/tmp');
    expect(AppController.kittyDir({'POCKETTERM_KITTY_DIR': ''}), '/tmp');
    expect(AppController.kittyDir({'POCKETTERM_KITTY_DIR': '/tmp/pocketterm-e2e'}), '/tmp/pocketterm-e2e');
  });

  testWidgets('the server ending the session clears the desktop widget and the Dock count too', (tester) async {
    final app = await FakeApp.create();
    // Not through signOut(): the server refused a refresh, or the account was deleted on another device.
    await app.signedOutByServer();
    expect(app.calls, containsAll(['setTodoCount', 'setSharedTodos']));
  });
}
