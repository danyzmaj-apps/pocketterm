import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pocketterm_core/wezterm.dart';

enum WezTermSetupState {
  /// Not installed, nothing going on.
  missing,

  /// Fetching WezTerm's installer.
  downloading,

  /// WezTerm's installer is open: the person clicks through it.
  installing,

  /// WezTerm is on this PC.
  installed,
}

/// WezTerm on Windows, the one terminal PocketTerm drives there. [install]
/// fetches WezTerm's own installer for the release PocketTerm is tested
/// with from WezTerm's GitHub release, checks it against the SHA-256 WezTerm
/// publishes, and opens it: the person sees WezTerm's usual setup and
/// Windows' admin prompt, nothing runs silently. Whichever way WezTerm
/// arrives (this, or [wingetCommand] in a terminal), [installed] turns true
/// within the constructor's `poll`.
class WezTermSetup extends ChangeNotifier {
  WezTermSetup({
    required this.isInstalled,
    http.Client? client,
    Directory? downloads,
    Future<Process> Function(String path)? run,
    Duration poll = const Duration(seconds: 2),
    this.checksum = sha256Hex,
  }) : _client = client ?? http.Client(),
       _downloads = downloads ?? Directory(p.join(Directory.systemTemp.path, 'pocketterm')),
       _run = run ?? ((path) => Process.start(path, const [])) {
    if (isInstalled()) {
      state = WezTermSetupState.installed;
    } else {
      _timer = Timer.periodic(poll, (_) => _look());
    }
  }

  /// This PC's: on Windows, for its WezTerm [host]; null elsewhere (a Mac
  /// has other terminals, and WezTerm there is the person's choice).
  static WezTermSetup? forHost(WezTerm? host) =>
      Platform.isWindows && host != null ? WezTermSetup(isInstalled: () => host.installed) : null;

  /// The release PocketTerm is tested with, and its installer's SHA-256 as
  /// WezTerm publishes it (`<installer>.sha256` on the release).
  static const version = '20240203-110809-5046fc22';
  static const sha256Hex = '35a6ec0eff7aa65e3987f14223bfb9df831eaab2964eb441ed6cad4356d252ff';
  static const _file = 'WezTerm-$version-setup.exe';
  static final Uri url = Uri.parse('https://github.com/wez/wezterm/releases/download/$version/$_file');

  /// The same, typed into PowerShell or Command Prompt.
  static const wingetCommand = 'winget install --id wez.wezterm --exact';

  /// Whether WezTerm is on this PC now.
  final bool Function() isInstalled;
  final http.Client _client;
  final Directory _downloads;
  final Future<Process> Function(String path) _run;

  /// The installer's SHA-256 a download must have to be opened.
  final String checksum;
  Timer? _timer;

  WezTermSetupState state = WezTermSetupState.missing;

  /// While downloading: how far, 0–1; null while the size is unknown.
  double? progress;

  /// Why the last [install] stopped.
  String? error;

  bool get installed => state == WezTermSetupState.installed;

  /// What it's doing, for a row's note; null when there's nothing to say.
  String? get note => switch (state) {
    WezTermSetupState.downloading =>
      'Downloading WezTerm${progress == null ? '' : ' · ${(progress! * 100).round()}%'}…',
    WezTermSetupState.installing => "WezTerm's installer is open: click through it, then come back here.",
    WezTermSetupState.installed => null,
    WezTermSetupState.missing => error,
  };

  void _look() {
    if (!isInstalled()) return;
    _timer?.cancel();
    _timer = null;
    state = WezTermSetupState.installed;
    error = null;
    notifyListeners();
  }

  void _set(WezTermSetupState s, {String? error, double? progress}) {
    state = s;
    this.error = error;
    this.progress = progress;
    notifyListeners();
  }

  /// Downloads, checks and opens WezTerm's installer; done once WezTerm is
  /// found. A second call while one runs does nothing.
  Future<void> install() async {
    if (state != WezTermSetupState.missing) return;
    _set(WezTermSetupState.downloading);
    final File file;
    try {
      file = await _download();
    } on Object catch (e) {
      if (state == WezTermSetupState.downloading) {
        _set(WezTermSetupState.missing, error: e is _Mismatch ? e.message : "WezTerm didn't download: $e");
      }
      return;
    }
    if (state != WezTermSetupState.downloading) return;
    _set(WezTermSetupState.installing);
    try {
      final process = await _run(file.path);
      await process.exitCode;
    } on Object catch (e) {
      if (state == WezTermSetupState.installing) {
        _set(WezTermSetupState.missing, error: "WezTerm's installer didn't open: $e");
      }
      return;
    }
    // The installer has closed: installed, or given up on.
    _look();
    if (state == WezTermSetupState.installing) {
      _set(WezTermSetupState.missing, error: 'The installer closed before WezTerm was installed.');
    }
  }

  Future<File> _download() async {
    final response = await _client.send(http.Request('GET', url));
    if (response.statusCode != 200) throw HttpException('GitHub answered ${response.statusCode}');
    await _downloads.create(recursive: true);
    final file = File(p.join(_downloads.path, _file));
    final sink = file.openWrite();
    final digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    final total = response.contentLength;
    var got = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        hash.add(chunk);
        got += chunk.length;
        if (total != null && total > 0) {
          progress = got / total;
          notifyListeners();
        }
      }
    } finally {
      hash.close();
      await sink.close();
    }
    if (digest.value.toString() != checksum) {
      await file.delete();
      throw const _Mismatch();
    }
    return file;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client.close();
    super.dispose();
  }
}

class _Mismatch implements Exception {
  const _Mismatch();
  String get message => "The download didn't match WezTerm's published checksum, so PocketTerm didn't open it.";
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
