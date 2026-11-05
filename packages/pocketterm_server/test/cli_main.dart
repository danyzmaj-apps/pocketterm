import 'dart:io';

import 'package:pocketterm_server/pocketterm_server.dart';

/// `pocketterm-server` as a process (cli_test.dart).
Future<void> main(List<String> args) async => exit(await runCli(args));
