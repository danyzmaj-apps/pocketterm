// Writes interop vectors for the relay's sealed requests: a throwaway relay key pair and bodies this package
// sealed to it. apps/pocketterm-relay/tests/seal_test.ts opens them with the relay's own code.
//
//   dart run tool/relay_vectors.dart ../../apps/pocketterm-relay/tests/vectors.json
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:pocketterm_server/src/relay.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/relay_vectors.dart <out.json>');
    exit(64);
  }
  final relay = await X25519().newKeyPair();
  final publicKey = (await relay.extractPublicKey()).bytes;
  final plains = [
    jsonEncode({'token': 'a' * 64, 'kind': 'terminal', 'enc': 'c2VhbGVk', 'desktop': 'k3x9m2qa'}),
    jsonEncode({'platform': 'android', 'token': 'f' * 160, 'kind': 'terminal', 'enc': 'x' * 3000}),
    '',
    'not json, still sealed: ünïcødé',
  ];
  final cases = [
    for (final plain in plains) {'plain': plain, 'sealed': await sealForRelay(publicKey, utf8.encode(plain))},
  ];
  File(args.single).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'note': 'Throwaway test key; written by packages/pocketterm_server/tool/relay_vectors.dart', 'relayPrivate': base64.encode(await relay.extractPrivateKeyBytes()), 'relayPublic': base64.encode(publicKey), 'cases': cases})}\n',
  );
}
