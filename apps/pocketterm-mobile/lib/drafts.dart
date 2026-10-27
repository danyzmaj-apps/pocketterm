import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Unsent prompt text, per session, kept across leaving the page and app
/// restarts until it's sent or deleted. Text only: attachments are too large
/// to keep. Stored as `pocketterm_draft_<desktopId>/<sessionKey>` (the routed
/// key, so sessions of two computers don't share one) holding
/// `{"t": text, "at": ms since epoch}`.
const _prefix = 'pocketterm_draft_';

/// Drafts untouched this long are dropped.
const _keep = Duration(days: 30);

String draftKey(String routedKey) => '$_prefix$routedKey';

/// [routedKey]'s draft, or '' when there's none. Drops stale drafts on the way.
Future<String> loadDraft(String routedKey) async {
  final prefs = await SharedPreferences.getInstance();
  final old = DateTime.now().subtract(_keep).millisecondsSinceEpoch;
  var text = '';
  for (final k in prefs.getKeys().where((k) => k.startsWith(_prefix)).toList()) {
    final d = _decode(prefs.getString(k));
    if (d == null || d.at < old) {
      await prefs.remove(k);
    } else if (k == draftKey(routedKey)) {
      text = d.t;
    }
  }
  return text;
}

/// Keeps [text] as [routedKey]'s draft; blank removes it.
Future<void> saveDraft(String routedKey, String text) async {
  final prefs = await SharedPreferences.getInstance();
  if (text.trim().isEmpty) {
    await prefs.remove(draftKey(routedKey));
  } else {
    await prefs.setString(draftKey(routedKey), jsonEncode({'t': text, 'at': DateTime.now().millisecondsSinceEpoch}));
  }
}

({String t, int at})? _decode(String? s) {
  if (s == null) return null;
  try {
    final m = jsonDecode(s);
    if (m is Map && m['t'] is String && m['at'] is int) return (t: m['t'] as String, at: m['at'] as int);
  } on FormatException {
    return null;
  }
  return null;
}
