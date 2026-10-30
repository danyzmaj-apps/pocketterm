import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/speech.dart';

void main() {
  test('Auto tries the phone languages it knows in the phone’s order, then English', () {
    const en = SpeechLanguage.english;
    const hr = SpeechLanguage.croatian;
    expect(SpeechLanguage.byLocales(const [Locale('hr', 'HR'), Locale('en', 'US')]), [hr, en]);
    expect(SpeechLanguage.byLocales(const [Locale('en', 'GB'), Locale('hr')]), [en, hr]);
    expect(SpeechLanguage.byLocales(const [Locale('de'), Locale('hr')]), [hr, en]);
    expect(SpeechLanguage.byLocales(const [Locale('de'), Locale('sl')]), [en]);
    expect(SpeechLanguage.byLocales(const []), [en]);
  });
}
