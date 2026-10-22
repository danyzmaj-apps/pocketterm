import 'dart:io';

/// A build made for tool/smoke or tool/e2e (`--dart-define=POCKETTERM_SMOKE=true`). Only such a build reads the
/// environment variables that point PocketTerm at stand-ins: `POCKETTERM_TAILSCALE` (the Tailscale CLI),
/// `POCKETTERM_CLI_JSON` (where the local API's port and token go), `POCKETTERM_KITTY_DIR` (kitty's sockets) and
/// `POCKETTERM_PROFILE` (secrets in memory, the accessibility tree on). A released build ignores them.
const testBuild = bool.fromEnvironment('POCKETTERM_SMOKE');

/// Where those variables are read from: this process's environment in a [testBuild], none otherwise.
Map<String, String> testHooks() => testBuild ? Platform.environment : const {};
