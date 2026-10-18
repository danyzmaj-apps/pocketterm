import 'package:pocketterm_mobile/mobile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

/// A phone signed in as `ana`, with nothing behind it: no disk, no Supabase.
class FakeSession extends MobileSession {
  FakeSession._(SharedPreferences prefs) : super(prefs, 'iPhone');

  static Future<FakeSession> create() async {
    SharedPreferences.setMockInitialValues({});
    return FakeSession._(await SharedPreferences.getInstance());
  }

  @override
  User? get user => const User(id: 'user', appMetadata: {}, userMetadata: {}, aud: 'authenticated', createdAt: '');

  @override
  String get userName => 'ana';

  @override
  String? get avatarUrl => null;
}
