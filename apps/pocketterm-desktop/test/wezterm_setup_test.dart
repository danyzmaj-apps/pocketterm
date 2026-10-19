import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocketterm_desktop/wezterm_setup.dart';

/// WezTerm's installer, as far as PocketTerm sees it: it runs until [close].
class _Installer implements Process {
  final _exit = Completer<int>();
  void close() => _exit.complete(0);

  @override
  Future<int> get exitCode => _exit.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  final bytes = utf8.encode('WezTerm setup');
  final good = sha256.convert(bytes).toString();

  setUp(() => dir = Directory.systemTemp.createTempSync('pocketterm_wezterm_setup'));
  tearDown(() => dir.deleteSync(recursive: true));

  MockClient serving(List<int> body) => MockClient((req) async {
    expect(req.url, WezTermSetup.url);
    return http.Response.bytes(body, 200);
  });

  test("downloads WezTerm's installer, opens it, and is done once WezTerm is found", () async {
    var installed = false;
    final installer = _Installer();
    final opened = <String>[];
    final setup = WezTermSetup(
      isInstalled: () => installed,
      client: serving(bytes),
      downloads: dir,
      checksum: good,
      poll: const Duration(milliseconds: 10),
      run: (path) async {
        opened.add(path);
        return installer;
      },
    );
    addTearDown(setup.dispose);

    final going = setup.install();
    await pumpEventQueue();
    expect(setup.state, WezTermSetupState.installing);
    expect(opened, hasLength(1));
    expect(File(opened.single).readAsBytesSync(), bytes, reason: 'the installer it opens is the download');

    installed = true;
    installer.close();
    await going;
    expect(setup.state, WezTermSetupState.installed);
    expect(setup.error, isNull);
  });

  test("a download that doesn't match the published checksum is never opened", () async {
    final opened = <String>[];
    final setup = WezTermSetup(
      isInstalled: () => false,
      client: serving(utf8.encode('something else')),
      downloads: dir,
      checksum: good,
      run: (path) async {
        opened.add(path);
        return _Installer();
      },
    );
    addTearDown(setup.dispose);

    await setup.install();
    expect(opened, isEmpty);
    expect(setup.state, WezTermSetupState.missing);
    expect(setup.error, contains('checksum'));
    expect(dir.listSync(), isEmpty, reason: 'the bad download is deleted');
  });

  test('closing the installer without installing leaves it missing, ready to try again', () async {
    final installer = _Installer();
    final setup = WezTermSetup(
      isInstalled: () => false,
      client: serving(bytes),
      downloads: dir,
      checksum: good,
      run: (_) async => installer,
    );
    addTearDown(setup.dispose);

    final going = setup.install();
    await pumpEventQueue();
    installer.close();
    await going;
    expect(setup.state, WezTermSetupState.missing);
    expect(setup.error, isNotNull);
  });

  test('WezTerm installed another way (winget) is noticed without a click', () async {
    var installed = false;
    final setup = WezTermSetup(
      isInstalled: () => installed,
      client: serving(bytes),
      downloads: dir,
      poll: const Duration(milliseconds: 10),
    );
    addTearDown(setup.dispose);
    expect(setup.state, WezTermSetupState.missing);

    installed = true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(setup.state, WezTermSetupState.installed);
  });
}
