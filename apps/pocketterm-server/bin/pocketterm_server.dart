import 'dart:io';

import 'package:pocketterm_server/pocketterm_server.dart';

Future<void> main(List<String> args) async => exit(await runCli(args));
