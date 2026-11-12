import 'dart:async';
import 'dart:io';

import 'package:pocketterm_server/pocketterm_server.dart';
import 'package:sentry/sentry.dart';

Future<void> main(List<String> args) async {
  final reports = errorReportOptions(Platform.environment);
  // Error reports are the operator's opt-in (POCKETTERM_SENTRY_DSN); without it the SDK never starts, so it never
  // reads a SENTRY_DSN of its own either.
  if (reports == null) exit(await runCli(args));
  try {
    await Sentry.init(reports);
  } on Object catch (e) {
    // A malformed POCKETTERM_SENTRY_DSN must not keep the server from starting.
    stderr.writeln('Error reports are off: $e');
    exit(await runCli(args));
  }
  // Our own guarded zone rather than Sentry's appRunner, which keeps the process running after an uncaught error:
  // with reports on, the server still ends the way it does without them (the VM's message and exit code 255).
  await runZonedGuarded(() async {
    final code = await runCli(args);
    await Sentry.close();
    exit(code);
  }, (error, stack) => unawaited(_crash(error, stack)));
}

Future<void> _crash(Object error, StackTrace stack) async {
  stderr.writeln('Unhandled exception:\n$error\n$stack');
  await Sentry.captureEvent(
    SentryEvent(
      throwable: ThrowableMechanism(Mechanism(type: 'runZonedGuarded', handled: false), error),
      level: SentryLevel.fatal,
    ),
    stackTrace: stack,
  );
  await Sentry.close();
  exit(255);
}
