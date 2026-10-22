import 'dart:io';

import 'package:pocketterm_server/src/store.dart';

/// Holds the data directory in args[0] the way a running server does, until stdin closes (edge_test.dart): another
/// process, since a lock is only exclusive between processes.
Future<void> main(List<String> args) async {
  final store = Store.open(Directory(args.single));
  stdout.writeln('held');
  await stdin.drain<void>();
  store.close();
}
