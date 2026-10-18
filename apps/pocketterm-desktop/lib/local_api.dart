import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pocketterm_desktop/live_hub.dart';

/// The terminal's way in (the live sessions of omp and Claude Code): HTTP
/// on 127.0.0.1 at a random port, guarded by a random token. Both are
/// written to `~/.config/pocketterm/cli.json`
/// (mode 600; `POCKETTERM_CLI_JSON` names another file) for the clients to read,
/// and taken out again when PocketTerm quits.
///
///   GET   /v1/ping?nonce=N         → {"app": "pocketterm", "proof"}: no token; proof is
///                                  [pingProof], so a client knows it's this PocketTerm
///                                  before its token goes anywhere
///   GET   /v1/ping                 → {"app": "pocketterm", "pid"}: this PocketTerm is up
///   GET   /v1/live                 WebSocket: a coding session reporting itself (omp's
///                                  integrations/omp/pocketterm-live.ts, lib/live_hub.dart)
///   POST  /v1/live/http            {conn?, frames, wait?} → {conn, frames}: the same over
///                                  HTTP long polls (the Claude Code plugin); packages/pocketterm_core/lib/live.dart
class LocalApi {
  LocalApi(this._live, {File? file})
    : file = file ?? _defaultFile(),
      _ownFolder = file == null && !_named(Platform.environment);

  final LiveHub _live;
  HttpServer? _server;
  late final String _token = List.generate(
    32,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  /// What this app wrote to [file].
  String? _written;
  Timer? _watch;

  /// How often [file] is checked for another PocketTerm having taken it over.
  static const _watchEvery = Duration(seconds: 5);

  /// HTTP long-poll connections (/v1/live/http) by id.
  final _polls = <String, _PollLink>{};

  /// How long a long poll waits for frames from the Mac.
  static const pollHold = Duration(seconds: 25);

  /// Where the port and token go: `~/.config/pocketterm/cli.json`, or the file
  /// `POCKETTERM_CLI_JSON` names.
  final File file;

  /// [file]'s folder is PocketTerm's own `~/.config/pocketterm`, kept private (700).
  /// One `POCKETTERM_CLI_JSON` names (a home folder, a project) keeps its mode.
  final bool _ownFolder;

  static bool _named(Map<String, String> env) => env['POCKETTERM_CLI_JSON']?.isNotEmpty ?? false;

  static File _defaultFile() {
    final env = Platform.environment;
    return File(_named(env) ? env['POCKETTERM_CLI_JSON']! : '${env['HOME']}/.config/pocketterm/cli.json');
  }

  /// The port it listens on, once started.
  int? get port => _server?.port;

  /// What /v1/ping?nonce= answers: HMAC-SHA256 under [token] of the
  /// [port] asked and the client's [nonce], in hex. Only the PocketTerm that
  /// wrote cli.json can make it, and only for its own port: whatever else
  /// listens there (after PocketTerm quit, say) can't, nor pass on a real PocketTerm's.
  static String pingProof(String token, int port, String nonce) =>
      Hmac(sha256, utf8.encode(token)).convert(utf8.encode('pocketterm-ping\n$port\n$nonce')).toString();

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(
      (req) => unawaited(switch (req.uri.path) {
        '/v1/live' => _upgrade(req),
        '/v1/live/http' => _poll(req),
        _ => _handle(req),
      }),
    );
    _written = jsonEncode({'port': server.port, 'token': _token, 'pid': pid});
    await _write();
    _watch = Timer.periodic(_watchEvery, (_) => unawaited(_reclaim()));
  }

  /// Stops listening and takes [file] back out, unless another PocketTerm has it
  /// now. Runs when PocketTerm quits (AppController.onQuit).
  Future<void> stop() async {
    _watch?.cancel();
    await _server?.close(force: true);
    for (final p in _polls.values.toList()) {
      await p.close();
    }
    final f = file;
    if (f.existsSync() && f.readAsStringSync() == _written) f.deleteSync();
  }

  /// Writes [_written] to [file] as a whole (a reader never sees half of it),
  /// private before the token goes in: a chmod that fails stops it.
  Future<void> _write() async {
    final f = file;
    await f.parent.create(recursive: true);
    if (_ownFolder) await _chmod('700', f.parent.path);
    final tmp = File('${f.path}.$pid.tmp');
    await tmp.writeAsString('');
    try {
      await _chmod('600', tmp.path);
      await tmp.writeAsString(_written!, flush: true);
      await tmp.rename(f.path);
    } on Object {
      if (tmp.existsSync()) await tmp.delete();
      rethrow;
    }
  }

  static Future<void> _chmod(String mode, String path) async {
    final r = await Process.run('/bin/chmod', [mode, path]);
    if (r.exitCode != 0) throw FileSystemException('chmod $mode failed: ${r.stderr}'.trim(), path);
  }

  /// Another PocketTerm (a debug build, say) took [file] over and has quit or
  /// died since, leaving the terminal pointed at nothing: this one's address
  /// goes back.
  Future<void> _reclaim() async {
    final f = file;
    String? text;
    try {
      text = f.existsSync() ? await f.readAsString() : null;
    } on FileSystemException {
      text = null;
    }
    if (!await shouldReclaim(text, _written!, answers: answers)) return;
    debugPrint('PocketTerm: ${f.path} named no running PocketTerm; writing this one back');
    try {
      await _write();
    } on Object catch (e) {
      debugPrint('PocketTerm: ${f.path} not written: $e');
    }
  }

  /// Whether cli.json as it reads now ([text], null when missing) should
  /// give way to [ours]: it's gone or unreadable, or names a PocketTerm that
  /// doesn't [answers] at its port with its token anymore.
  @visibleForTesting
  static Future<bool> shouldReclaim(
    String? text,
    String ours, {
    required Future<bool> Function(int port, String token) answers,
  }) async {
    if (text == ours) return false;
    final Object? json;
    try {
      json = jsonDecode(text ?? '');
    } on FormatException {
      return true;
    }
    if (json is! Map || json['port'] is! int || json['token'] is! String) return true;
    return !await answers(json['port'] as int, json['token'] as String);
  }

  /// The PocketTerm that holds [token] answers /v1/ping at [port]: it proves it
  /// ([pingProof]) without the token being sent.
  @visibleForTesting
  static Future<bool> answers(int port, String token) async {
    final nonce = _newId();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.get('127.0.0.1', port, '/v1/ping?nonce=$nonce');
      final res = await req.close().timeout(const Duration(seconds: 2));
      final body = jsonDecode(await utf8.decodeStream(res).timeout(const Duration(seconds: 2)));
      return res.statusCode == 200 && body is Map && body['proof'] == pingProof(token, port, nonce);
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _upgrade(HttpRequest req) async {
    if (req.headers.value('authorization') != 'Bearer $_token' || !WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    await _live.accept(ws.where((f) => f is String).cast<String>(), SocketLink(ws));
  }

  /// One long poll: the extension's frames go to its connection in order,
  /// and the answer carries the Mac's, waiting [pollHold] for some when
  /// asked to. A request without a connection opens one.
  Future<void> _poll(HttpRequest req) async {
    final res = req.response..headers.contentType = ContentType.json;
    try {
      if (req.method != 'POST') {
        res.statusCode = HttpStatus.methodNotAllowed;
      } else if (req.headers.value('authorization') != 'Bearer $_token') {
        res
          ..statusCode = HttpStatus.forbidden
          ..write(jsonEncode({'error': 'Bad token.'}));
      } else {
        final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
        final id = body['conn'] as String?;
        final _PollLink? link;
        if (id == null) {
          link = _PollLink(_newId(), _polls.remove);
          _polls[link.id] = link;
          unawaited(_live.accept(link.frames, link));
        } else {
          link = _polls[id];
        }
        final out = await link?.exchange([
          for (final f in body['frames'] as List? ?? const []) jsonEncode(f),
        ], hold: body['wait'] == true ? pollHold : null);
        // The agent is quitting: its session ends now.
        if (body['close'] == true) await link?.close();
        if (out == null) {
          res
            ..statusCode = HttpStatus.notFound
            ..write(jsonEncode({'error': 'No such connection: say hello again.'}));
        } else {
          // The hub's frames are JSON already.
          res.write('{"conn":${jsonEncode(link!.id)},"frames":[${out.join(',')}]}');
        }
      }
    } on Object catch (e) {
      debugPrint('PocketTerm: live poll: $e');
      res
        ..statusCode = HttpStatus.badRequest
        ..write(jsonEncode({'error': 'Bad request: $e'}));
    }
    try {
      await res.close();
    } on Object catch (e) {
      // The extension gave up on a long poll.
      debugPrint('PocketTerm: live poll: $e');
    }
  }

  static String _newId() =>
      List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  Future<void> _handle(HttpRequest req) async {
    final res = req.response..headers.contentType = ContentType.json;
    try {
      final (status, body) = _route(req);
      res
        ..statusCode = status
        ..write(jsonEncode(body));
    } on Object catch (e) {
      debugPrint('PocketTerm: API error: $e');
      res
        ..statusCode = 400
        ..write(jsonEncode({'error': 'Bad request: $e'}));
    }
    await res.close();
  }

  (int, Map<String, dynamic>) _route(HttpRequest req) {
    final path = req.uri.pathSegments;
    final ping = req.method == 'GET' && path.length == 2 && path[0] == 'v1' && path[1] == 'ping';
    // Before the token: a client asks this way whether to send it here.
    if (req.uri.queryParameters['nonce'] case final nonce? when ping) {
      if (nonce.length < 16 || nonce.length > 128) return (400, {'error': 'nonce: 16 to 128 characters.'});
      return (200, {'app': 'pocketterm', 'proof': pingProof(_token, port!, nonce)});
    }
    if (req.headers.value('authorization') != 'Bearer $_token') return (403, {'error': 'Bad token.'});
    if (ping) return (200, {'app': 'pocketterm', 'pid': pid});
    return (404, {'error': 'Not found.'});
  }
}

/// One extension on the HTTP long-poll transport (/v1/live/http): its frames
/// go to the hub in the order they came, and the hub's wait here for its
/// next request. Gone, and its session with it, after [idle] without one.
class _PollLink implements LiveLink {
  _PollLink(this.id, this._gone) {
    _idleTimer = Timer(idle, () => unawaited(close()));
  }

  final String id;
  final void Function(String id) _gone;
  static const idle = Duration(seconds: 60);

  final _in = StreamController<String>();
  final _out = <String>[];
  Completer<void>? _waiting;
  Timer? _idleTimer;
  int _active = 0;
  bool _closed = false;

  /// The extension's frames, for LiveHub.accept.
  Stream<String> get frames => _in.stream;

  @override
  void send(String frame) {
    if (_closed) return;
    _out.add(frame);
    _wake();
  }

  void _wake() {
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _idleTimer?.cancel();
    _wake();
    _gone(id);
    await _in.close();
  }

  /// One request: [frames] in, then the hub's out, waiting up to [hold] for
  /// some when there are none yet (a newer wait ends an older one). Null
  /// once closed.
  Future<List<String>?> exchange(List<String> frames, {Duration? hold}) async {
    if (_closed) return null;
    _active++;
    _idleTimer?.cancel();
    try {
      frames.forEach(_in.add);
      if (_out.isEmpty && hold != null) {
        _wake();
        final w = _waiting = Completer<void>();
        await w.future.timeout(hold, onTimeout: () {});
      }
      final out = [..._out];
      _out.clear();
      return out;
    } finally {
      if (--_active == 0 && !_closed) _idleTimer = Timer(idle, () => unawaited(close()));
    }
  }
}
