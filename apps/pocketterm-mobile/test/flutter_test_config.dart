import 'dart:async';

import 'package:pocketterm_mobile/state_border.dart';

/// Every test here: a working session's border holds still, so pumpAndSettle can settle.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  StateBorder.runs = false;
  await testMain();
}
