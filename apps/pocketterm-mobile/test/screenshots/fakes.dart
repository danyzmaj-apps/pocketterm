import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_mobile/coach.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The key a [FakeSession] holds for every computer not [FakeSession.locked].
final testKey = ChannelKey(List.filled(32, 9));

/// A server nothing is asked of: the remotes and lists handed in talk
/// through their own fakes.
PocketTermServerClient offlineServer() =>
    PocketTermServerClient(const Backend(url: 'http://localhost:1'), tokens: MemoryDeviceTokens());

/// A phone signed in to `ana.example.com` (or, with `signedIn: false`, not
/// yet), with nothing behind it: no disk, no server. Its first-use tips are
/// all seen unless `tips`; not `fresh`, it keeps the phone's prefs from
/// before (the app started again). It holds [testKey] for every computer
/// but the [locked] ones.
class FakeSession extends MobileSession {
  FakeSession._(SharedPreferences prefs, this._signedIn) : super(prefs, 'iPhone');

  final bool _signedIn;

  /// Computers whose code this phone hasn't scanned.
  final locked = <String>{};

  /// The server it's connected to, for setup links; none unless set.
  Backend? connected;

  @override
  Backend? get backend => connected;

  @override
  ChannelKey? computerKey(String desktopId) =>
      super.computerKey(desktopId) ?? (locked.contains(desktopId) ? null : testKey);

  static Future<FakeSession> create({bool signedIn = true, bool tips = false, bool fresh = true}) async {
    if (fresh) {
      SharedPreferences.setMockInitialValues({
        if (!tips) CoachController.seenKey: [for (final t in Tip.values) t.id],
      });
    }
    return FakeSession._(await SharedPreferences.getInstance(), signedIn);
  }

  @override
  Account? get user => _signedIn
      ? const Account(
          id: 'server',
          device: Device(id: 'phone', role: DeviceRole.phone, label: 'iPhone', platform: 'ios'),
        )
      : null;

  @override
  String get userName => 'ana.example.com';
}
