import 'package:flutter/foundation.dart';

/// A debug build made for the end-to-end tests (maestro/e2e/run.sh builds
/// with `--dart-define=POCKETTERM_E2E=true`): the scanner takes a pasted code
/// (the Simulator has no camera) and the first-use tips start out seen until
/// Show tips again. Always false in release and profile builds, where
/// [kDebugMode] is a constant false and what it guards is compiled out.
const bool e2eBuild = kDebugMode && bool.fromEnvironment('POCKETTERM_E2E');
