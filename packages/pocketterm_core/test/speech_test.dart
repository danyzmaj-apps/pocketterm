import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/speech.dart';

void main() {
  test('Auto listens in the first of the phone languages it knows, English when it knows none', () {
    expect(SpeechLanguage.fromLocales(const [Locale('hr', 'HR'), Locale('en', 'US')]), SpeechLanguage.croatian);
    expect(SpeechLanguage.fromLocales(const [Locale('en', 'GB'), Locale('hr')]), SpeechLanguage.english);
    expect(SpeechLanguage.fromLocales(const [Locale('de'), Locale('hr')]), SpeechLanguage.croatian);
    expect(SpeechLanguage.fromLocales(const [Locale('de'), Locale('sl')]), SpeechLanguage.english);
    expect(SpeechLanguage.fromLocales(const []), SpeechLanguage.english);
  });
}
