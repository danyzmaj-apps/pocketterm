import 'package:pocketterm_mobile/coach.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

/// A phone signed in as `ana` (or, with `signedIn: false`, not yet; with
/// `demo: true`, as the store reviewers' demo account), with nothing behind
/// it: no disk, no Supabase. Its first-use tips are all seen unless `tips`;
/// not `fresh`, it keeps the phone's prefs from before (the app started again).
class FakeSession extends MobileSession {
  FakeSession._(SharedPreferences prefs, this._signedIn, this._demo) : super(prefs, 'iPhone');

  final bool _signedIn;
  final bool _demo;

  static Future<FakeSession> create({
    bool signedIn = true,
    bool demo = false,
    bool tips = false,
    bool fresh = true,
  }) async {
    if (fresh) {
      SharedPreferences.setMockInitialValues({
        if (!tips) CoachController.seenKey: [for (final t in Tip.values) t.id],
      });
    }
    return FakeSession._(await SharedPreferences.getInstance(), signedIn, demo);
  }

  @override
  User? get user => _signedIn
      ? User(
          id: 'user',
          appMetadata: {if (_demo) 'pocketterm_demo': true},
          userMetadata: const {},
          aud: 'authenticated',
          createdAt: '',
        )
      : null;

  @override
  String get userName => 'ana';

  @override
  String? get avatarUrl => null;
}
