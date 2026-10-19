import 'package:pocketterm_mobile/mobile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

/// A phone signed in as `ana` (or, with `signedIn: false`, not yet), with nothing
/// behind it: no disk, no Supabase.
class FakeSession extends MobileSession {
  FakeSession._(SharedPreferences prefs, this._signedIn) : super(prefs, 'iPhone');

  final bool _signedIn;

  static Future<FakeSession> create({bool signedIn = true}) async {
    SharedPreferences.setMockInitialValues({});
    return FakeSession._(await SharedPreferences.getInstance(), signedIn);
  }

  @override
  User? get user =>
      _signedIn ? const User(id: 'user', appMetadata: {}, userMetadata: {}, aud: 'authenticated', createdAt: '') : null;

  @override
  String get userName => 'ana';

  @override
  String? get avatarUrl => null;
}
