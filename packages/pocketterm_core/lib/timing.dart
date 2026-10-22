import 'package:flutter/foundation.dart';

/// Debug builds only: one step of getting connected (the sign-in read, the
/// computers fetched, the WebSocket up, the computer's first state, a
/// session caught up), logged as `PocketTerm timing <epoch ms> <what>` for
/// the end-to-end run's timing report (apps/pocketterm-mobile/maestro/e2e/
/// run.sh). In release and profile builds [kDebugMode] is a constant false
/// and the call does nothing; pass constant text, so nothing is built for it
/// there either.
void timing(String what) {
  if (!kDebugMode) return;
  debugPrint('PocketTerm timing ${DateTime.now().millisecondsSinceEpoch} $what');
}
