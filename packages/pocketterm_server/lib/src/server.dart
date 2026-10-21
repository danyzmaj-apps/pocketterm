import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pocketterm_server/src/hub.dart';
import 'package:pocketterm_server/src/relay.dart';
import 'package:pocketterm_server/src/secrets.dart';
import 'package:pocketterm_server/src/store.dart';

/// This protocol's version, `pocketterm` in `GET /v1/health` (see PROTOCOL.md).
const protocolVersion = 1;

/// The server's own version.
const serverVersion = '0.1.0';

/// The largest JSON request body (64 KiB).
const int maxJsonBytes = 64 * 1024;

/// The largest blob (20 MiB).
const int maxBlobBytes = 20 * 1024 * 1024;

/// How long a blob nobody downloads is kept.
const blobTtl = Duration(hours: 1);

/// How long a pairing code works.
const pairingCodeTtl = Duration(minutes: 10);

/// Failed redeems one address may make in [redeemWindow] before it waits.
const maxRedeemFailures = 10;
const redeemWindow = Duration(minutes: 10);

const _desktopPlatforms = {'macos', 'windows', 'linux'};
const _phonePlatforms = {'ios', 'android'};
const _activityStates = ['working', 'needs', 'done', 'ended'];
const _activityKinds = ['question', 'approval', 'plan'];

final _desktopId = RegExp(r'^[a-z0-9]{8}$');
final _blobPath = RegExp(r'^[A-Za-z0-9-]{1,64}$');
final _sessionKey = RegExp(r'^[\w.:/-]{1,64}$');
final _fcmToken = RegExp(r'^[A-Za-z0-9_:\-]{100,4096}$');

/// The relay takes at most 3000 base64 characters (FCM's 4 KB of data in all).
const _maxEnc = 3000;

/// A request that ends in an error answer: `{error, message}` with [status].
class _Fail implements Exception {
  _Fail(this.status, this.code, this.message, {this.retryAfter});

  final int status;
  final String code;
  final String message;
  final Duration? retryAfter;
}

_Fail _bad(String message) => _Fail(400, 'bad_request', message);

/// PocketTerm's own server for one owner: devices, pairing, desktops, blobs, push forwarding and the live
/// channel over WebSocket. Everything it keeps lives in one data directory. See PROTOCOL.md.
class PocketTermServer {
  PocketTermServer._(this._dir, this._http, this._store, this._relay, this.publicUrl, this._now, this._trustProxy);

  /// Starts serving on [address]:[port] (0 picks a free port; see [port]). [publicUrl] is the address phones
  /// and computers reach it at, put in setup links. [relay] is the push relay (default: the publisher's).
  /// With [trustProxy], the caller's address for rate limits is the last one in X-Forwarded-For (set it only
  /// behind a reverse proxy). [clock] stands in for the time in tests.
  static Future<PocketTermServer> start({
    required Directory dataDir,
    required InternetAddress address,
    required int port,
    required Uri publicUrl,
    Uri? relay,
    bool trustProxy = false,
    void Function(String message)? log,
    DateTime Function()? clock,
  }) async {
    final store = Store.open(dataDir);
    Store.setupToken(dataDir);
    Directory('${dataDir.path}/blobs').createSync(recursive: true);
    final http = await HttpServer.bind(address, port);
    final server = PocketTermServer._(
      dataDir,
      http,
      store,
      Relay(relay ?? defaultRelay, log: log),
      publicUrl,
      clock ?? DateTime.now,
      trustProxy,
    ).._log = log;
    server
      .._sweep()
      .._sweeper = Timer.periodic(const Duration(minutes: 1), (_) => server._sweep());
    http.listen((req) => unawaited(server._handle(req)));
    return server;
  }

  /// The setup link for computers of the server whose data is in [dataDir], reachable at [publicUrl]:
  /// `pocketterm://setup?url=<publicUrl>&setup=<token>`. With [replace], the setup token is
  /// replaced first (the old one stops working; devices stay signed in). Works whether or not it runs.
  static Uri setupLinkFor(Directory dataDir, Uri publicUrl, {bool replace = false}) {
    final token = replace ? Store.replaceSetupToken(dataDir) : Store.setupToken(dataDir);
    var url = publicUrl.toString();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return Uri(scheme: 'pocketterm', host: 'setup', queryParameters: {'url': url, 'setup': token});
  }

  final Directory _dir;
  final HttpServer _http;
  final Store _store;
  final Relay _relay;
  final Hub _hub = Hub();
  final DateTime Function() _now;
  final bool _trustProxy;
  final Map<String, List<DateTime>> _failures = {};
  void Function(String)? _log;
  Timer? _sweeper;

  /// What setup links point phones and computers at.
  final Uri publicUrl;

  /// The port it listens on.
  int get port => _http.port;

  /// Where it listens, e.g. `http://127.0.0.1:47900`.
  Uri get url => Uri(scheme: 'http', host: _http.address.address, port: port);

  /// The setup link for computers (see [setupLinkFor]).
  Uri setupLink() => setupLinkFor(_dir, publicUrl);

  /// Replaces the setup token and returns the new setup link.
  Uri newSetupToken() => setupLinkFor(_dir, publicUrl, replace: true);

  /// Stops serving: closes every WebSocket (1001) and the listener.
  Future<void> stop() async {
    _sweeper?.cancel();
    await _hub.closeAll();
    await _http.close(force: true);
    _relay.close();
  }

  Directory get _blobs => Directory('${_dir.path}/blobs');

  /// Forgets blobs past [blobTtl] (and half-written ones), expired pairing codes and old redeem failures.
  void _sweep() {
    final now = _now();
    try {
      for (final f in _blobs.listSync().whereType<File>()) {
        if (now.difference(f.lastModifiedSync()) > blobTtl) f.deleteSync();
      }
    } on FileSystemException catch (e) {
      _log?.call('blob sweep: $e');
    }
    final before = _store.pairingCodes.length;
    _store.pairingCodes.removeWhere((_, c) => !c.expires.isAfter(now));
    if (_store.pairingCodes.length != before) _store.save();
    _failures
      ..forEach((_, times) => times.removeWhere((t) => now.difference(t) >= redeemWindow))
      ..removeWhere((_, times) => times.isEmpty);
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      await _route(req);
    } on _Fail catch (e) {
      if (e.retryAfter != null) req.response.headers.set('retry-after', '${e.retryAfter!.inSeconds + 1}');
      await _json(req, e.status, {'error': e.code, 'message': e.message});
    } on Object catch (e, st) {
      _log?.call('${req.method} ${req.uri.path}: $e\n$st');
      try {
        await _json(req, 500, {'error': 'internal', 'message': 'Something went wrong on the server.'});
      } on Object {
        // The answer had already started.
      }
    }
  }

  Future<void> _route(HttpRequest req) async {
    final p = req.uri.pathSegments;
    if (p.length < 2 || p[0] != 'v1') throw _Fail(404, 'not_found', 'No such endpoint.');
    final m = req.method;
    void only(String method) {
      if (m != method) throw _Fail(405, 'method_not_allowed', '${req.uri.path} takes $method.');
    }

    switch (p.sublist(1)) {
      case ['health']:
        only('GET');
        return await _json(req, 200, {'pocketterm': protocolVersion, 'version': serverVersion});
      case ['setup', 'redeem']:
        only('POST');
        return await _redeem(req, _setupRedeem);
      case ['pair', 'redeem']:
        only('POST');
        return await _redeem(req, _pairRedeem);
      case ['pair']:
        only('POST');
        final me = _desktopOnly(_auth(req));
        final code = newPairingCode();
        final hash = sha256Hex(normalizePairingCode(code));
        final expires = _now().add(pairingCodeTtl);
        _store
          ..pairingCodes[hash] = PairingCode(hash: hash, expires: expires, by: me.id)
          ..save();
        return await _json(req, 200, {'code': code, 'expires': iso(expires)});
      case ['me']:
        only('GET');
        final me = _auth(req);
        return await _json(req, 200, {
          'device': me.toApi(),
          'server': {'id': _store.serverId},
        });
      case ['desktops']:
        only('GET');
        _auth(req);
        final list = _store.desktops.values.toList()..sort((a, b) => b.seen.compareTo(a.seen));
        final now = _now();
        return await _json(req, 200, [for (final d in list) d.toApi(now)]);
      case ['desktops', final id]:
        return await _desktop(req, id);
      case ['devices']:
        only('GET');
        final me = _auth(req);
        final list = _store.devices.values.toList()..sort((a, b) => a.created.compareTo(b.created));
        return await _json(req, 200, [
          for (final d in list) {...d.toApi(), 'current': d.id == me.id},
        ]);
      case ['devices', final id]:
        only('DELETE');
        final me = _auth(req);
        final target = id == 'me' ? me.id : id;
        if (target != me.id) _desktopOnly(me);
        if (!_store.devices.containsKey(target)) throw _Fail(404, 'not_found', 'No such device.');
        _dropDevice(target);
        return await _json(req, 200, {'ok': true});
      case ['erase']:
        only('POST');
        _desktopOnly(_auth(req));
        await _erase();
        return await _json(req, 200, {'ok': true});
      case ['blobs', final path]:
        return await _blob(req, path);
      case ['push', final action]:
        only('POST');
        final me = _auth(req);
        return await _json(req, 200, await _push(action, await _readJson(req), me.id));
      case ['ws']:
        only('GET');
        final me = _auth(req);
        if (!WebSocketTransformer.isUpgradeRequest(req)) throw _bad('Expected a WebSocket upgrade.');
        final ws = await WebSocketTransformer.upgrade(req);
        // Revoked while upgrading.
        if (!_store.devices.containsKey(me.id)) return await ws.close(closeRevoked, 'revoked');
        _hub.add(ws, me.id);
        return;
      default:
        throw _Fail(404, 'not_found', 'No such endpoint.');
    }
  }

  // Devices and redeeming.

  /// The device whose bearer token [req] carries; stamps its seen_at (kept to the minute).
  Device _auth(HttpRequest req) {
    final header = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final device = header.startsWith('Bearer ')
        ? _store.deviceByTokenHash(sha256Hex(header.substring(7).trim()))
        : null;
    if (device == null) throw _Fail(401, 'unauthorized', 'Sign in again: this device is not signed in to the server.');
    final now = _now();
    if (now.difference(device.seen) >= const Duration(minutes: 1)) {
      device.seen = now;
      _store.save();
    }
    return device;
  }

  Device _desktopOnly(Device d) {
    if (!d.isDesktop) throw _Fail(403, 'forbidden', 'Only a computer can do this.');
    return d;
  }

  /// Who sent [req], for the redeem throttle: the TCP peer, or behind a trusted proxy the address it put last
  /// in X-Forwarded-For.
  String _caller(HttpRequest req) {
    if (_trustProxy) {
      final forwarded = req.headers['x-forwarded-for']?.join(',').split(',').last.trim() ?? '';
      if (forwarded.isNotEmpty) return forwarded;
    }
    return req.connectionInfo?.remoteAddress.address ?? '';
  }

  /// Runs [redeem] under the throttle: an address with [maxRedeemFailures] failures in [redeemWindow] waits,
  /// and every 400 counts as a failure.
  Future<void> _redeem(HttpRequest req, Map<String, dynamic> Function(Map<String, dynamic>) redeem) async {
    final ip = _caller(req);
    final now = _now();
    final times = (_failures[ip] ??= [])..removeWhere((t) => now.difference(t) >= redeemWindow);
    if (times.length >= maxRedeemFailures) {
      throw _Fail(
        429,
        'rate_limited',
        'Too many tries. Wait a few minutes, then try again.',
        retryAfter: redeemWindow - now.difference(times.first),
      );
    }
    try {
      return await _json(req, 200, redeem(await _readJson(req)));
    } on _Fail catch (e) {
      if (e.status == 400) times.add(now);
      rethrow;
    }
  }

  Map<String, dynamic> _setupRedeem(Map<String, dynamic> body) {
    final platform = _platform(body, _desktopPlatforms);
    final setup = body['setup'];
    if (setup is! String || sha256Hex(setup) != sha256Hex(Store.setupToken(_dir))) {
      throw _Fail(
        400,
        'invalid_code',
        "That setup link doesn't work: it may have been replaced. Run `pocketterm-server setup-link` on the "
            'server for the current one.',
      );
    }
    return _newDevice('desktop', _label(body), platform);
  }

  Map<String, dynamic> _pairRedeem(Map<String, dynamic> body) {
    final platform = _platform(body, _phonePlatforms);
    final code = body['code'];
    final normalized = code is String ? normalizePairingCode(code) : '';
    final hash = sha256Hex(normalized);
    final found = normalized.length == pairingCodeLength ? _store.pairingCodes.remove(hash) : null;
    if (found == null || !found.expires.isAfter(_now())) {
      if (found != null) _store.save();
      throw _Fail(
        400,
        'invalid_code',
        "That code doesn't work: it may have run out or been used already. Make a new one in PocketTerm on "
            'your computer (Settings, Add a phone).',
      );
    }
    return _newDevice('phone', _label(body), platform);
  }

  /// A new device and its token (saved with any change made before, such as a used pairing code).
  Map<String, dynamic> _newDevice(String role, String label, String platform) {
    final token = newToken();
    final now = _now();
    var id = newId();
    while (_store.devices.containsKey(id)) {
      id = newId();
    }
    final device = Device(
      id: id,
      role: role,
      label: label,
      platform: platform,
      tokenHash: sha256Hex(token),
      created: now,
      seen: now,
    );
    _store
      ..devices[id] = device
      ..save();
    return {'token': token, 'device': device.toApi()};
  }

  /// Signs device [id] out for good: its token, its push and activity tokens and its sockets.
  void _dropDevice(String id) {
    _store
      ..devices.remove(id)
      ..pushTokens.removeWhere((_, t) => t.device == id)
      ..activityTokens.removeWhere((t) => t.device == id)
      ..save();
    _hub.closeDevice(id);
  }

  /// Erases everything the owner has here: every device (the caller too), computer, pairing code, push and
  /// activity token and blob; every socket closes with 4003. The setup token and the server id stay, so
  /// computers can set up again with the same link.
  Future<void> _erase() async {
    _store
      ..devices.clear()
      ..desktops.clear()
      ..pairingCodes.clear()
      ..pushTokens.clear()
      ..activityTokens.clear()
      ..save();
    for (final f in _blobs.listSync()) {
      f.deleteSync(recursive: true);
    }
    await _hub.closeAll(code: closeRevoked, reason: 'erased');
  }

  // Desktops.

  Future<void> _desktop(HttpRequest req, String id) async {
    final me = _auth(req);
    switch (req.method) {
      case 'PUT':
        _desktopOnly(me);
        if (!_desktopId.hasMatch(id)) throw _bad("The computer's id must be 8 characters a-z, 0-9.");
        final body = await _readJson(req);
        final name = body['name'];
        if (name is! String) throw _bad('name must be a string.');
        final desktop = Desktop(
          id: id,
          name: _clip(name, 80),
          platform: _platform(body, _desktopPlatforms),
          seen: _now(),
        );
        _store
          ..desktops[id] = desktop
          ..save();
        return await _json(req, 200, desktop.toApi(_now()));
      case 'DELETE':
        if (_store.desktops.remove(id) != null) _store.save();
        return await _json(req, 200, {'ok': true});
      default:
        throw _Fail(405, 'method_not_allowed', '${req.uri.path} takes PUT or DELETE.');
    }
  }

  // Blobs.

  Future<void> _blob(HttpRequest req, String path) async {
    _auth(req);
    if (!_blobPath.hasMatch(path)) throw _bad('A blob path is 1 to 64 characters A-Z, a-z, 0-9 and -.');
    final file = File('${_blobs.path}/$path');
    switch (req.method) {
      case 'PUT':
        if (file.existsSync()) throw _Fail(409, 'conflict', 'That blob path is taken.');
        if (req.contentLength > maxBlobBytes) {
          req.response.persistentConnection = false;
          throw _Fail(413, 'too_large', 'A blob is at most $maxBlobBytes bytes.');
        }
        final part = File('${_blobs.path}/.$path.${newId(8)}.part');
        final sink = part.openWrite();
        var size = 0;
        var tooLarge = false;
        try {
          await for (final chunk in req) {
            size += chunk.length;
            if (size > maxBlobBytes) {
              tooLarge = true;
              break;
            }
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        if (tooLarge) {
          part.deleteSync();
          req.response.persistentConnection = false;
          throw _Fail(413, 'too_large', 'A blob is at most $maxBlobBytes bytes.');
        }
        // Checked again: another upload to the same path may have finished meanwhile.
        if (file.existsSync()) {
          part.deleteSync();
          throw _Fail(409, 'conflict', 'That blob path is taken.');
        }
        part.renameSync(file.path);
        return await _json(req, 201, {'path': path});
      case 'GET':
        if (!file.existsSync()) throw _Fail(404, 'not_found', 'No such blob: it ran out or was downloaded.');
        if (_now().difference(file.lastModifiedSync()) > blobTtl) {
          file.deleteSync();
          throw _Fail(404, 'not_found', 'No such blob: it ran out or was downloaded.');
        }
        final res = req.response
          ..headers.contentType = ContentType.binary
          ..contentLength = file.lengthSync();
        try {
          await res.addStream(file.openRead());
          await res.close();
        } on Object catch (e) {
          // Not delivered in full: kept for another try.
          _log?.call('blob $path not sent: $e');
          return;
        }
        if (file.existsSync()) file.deleteSync();
        return;
      case 'DELETE':
        if (file.existsSync()) file.deleteSync();
        return await _json(req, 200, {'ok': true});
      default:
        throw _Fail(405, 'method_not_allowed', '${req.uri.path} takes PUT, GET or DELETE.');
    }
  }

  // Push: sealed notifications and Live Activity states, forwarded to the relay.

  Future<Map<String, dynamic>> _push(String action, Map<String, dynamic> body, String device) async {
    final platformValue = body['platform'];
    final platform = platformValue ?? 'ios';
    if (platform != 'ios' && platform != 'android') throw _bad('platform must be ios or android.');
    final token = body['token'];
    switch (action) {
      case 'register':
        _pushToken(token, platform as String);
        _store
          ..pushTokens[token as String] = PushToken(
            token: token,
            platform: platform,
            label: body['label'] is String ? _clip(body['label'] as String, 80) : '',
            device: device,
          )
          ..save();
        return {'ok': true};
      case 'unregister':
        if (token is String) {
          _store
            ..pushTokens.remove(token)
            // An Android phone's sessions follow its device token.
            ..activityTokens.removeWhere((t) => t.token == token)
            ..save();
        }
        return {'ok': true};
      case 'notify':
        final desktop = body['desktop'];
        if (desktop is! String || !_desktopId.hasMatch(desktop)) throw _bad("desktop must be the computer's id.");
        final enc = body['enc'];
        if (!_sealed(enc)) throw _bad('enc must be the sealed notification, base64, at most $_maxEnc.');
        final collapse = body['collapse'];
        if (collapse != null && !_isSessionKey(collapse)) throw _bad('collapse must be a coding session key.');
        return {'sent': await _notify(desktop, enc! as String, collapse as String?)};
      case 'activity_register':
        final session = body['session'];
        if (platform == 'android') {
          if (token is! String || !_fcmToken.hasMatch(token)) throw _bad('token must be the FCM registration token.');
        } else if (!_apnsToken(token, 400)) {
          throw _bad("token must be the activity's push token (hex).");
        }
        if (!_isSessionKey(session)) throw _bad('session must be a coding session key.');
        // An iPhone's activity follows one session for good.
        _store.activityTokens.removeWhere((t) => t.token == token && (t.session == session || platform == 'ios'));
        _store
          ..activityTokens.add(
            ActivityToken(
              token: token! as String,
              session: session! as String,
              platform: platform as String,
              device: device,
            ),
          )
          ..save();
        return {'ok': true};
      case 'activity_end':
        // No session ends every one this token follows; a bad one ends none.
        final session = body['session'];
        if (session != null && !_isSessionKey(session)) throw _bad('session must be a coding session key.');
        if (token is String) {
          _store
            ..activityTokens.removeWhere((t) => t.token == token && (session == null || t.session == session))
            ..save();
        }
        return {'ok': true};
      case 'activity':
        final session = body['session'];
        if (!_isSessionKey(session)) throw _bad('session must be a coding session key.');
        final state = body['state'];
        if (!_activityStates.contains(state)) throw _bad('state must be ${_activityStates.join(', ')}.');
        final kind = body['kind'];
        if (kind != null && !_activityKinds.contains(kind)) throw _bad('kind must be ${_activityKinds.join(', ')}.');
        return {'sent': await _activity(session! as String, state as String, kind as String?)};
      default:
        throw _Fail(404, 'not_found', 'No such endpoint.');
    }
  }

  /// Sends [enc], sealed on computer [desktop], to every phone; forgets the ones Apple or Google say are gone.
  Future<int> _notify(String desktop, String enc, String? collapse) async {
    var sent = 0;
    for (final t in _store.pushTokens.values.toList()) {
      final status = await _relay.post({
        if (t.platform == 'android') 'platform': 'android',
        'token': t.token,
        'kind': 'terminal',
        'enc': enc,
        'desktop': desktop,
        // Lets a newer push for the same coding session replace an older one.
        'collapse': ?collapse,
      });
      if (status == 410) {
        _store
          ..pushTokens.remove(t.token)
          ..save();
      } else if (status != null && status >= 200 && status < 300) {
        sent++;
      }
    }
    return sent;
  }

  /// Moves every Live Activity of coding [session] to [state] (ended: ends them).
  Future<int> _activity(String session, String state, String? kind) async {
    final live = {
      'state': state,
      'since': _now().millisecondsSinceEpoch ~/ 1000,
      if (state == 'needs' && kind != null) 'kind': kind,
    };
    var sent = 0;
    for (final t in _store.activityTokens.where((t) => t.session == session).toList()) {
      final status = await _relay.post(
        t.platform == 'android'
            ? {
                'platform': 'android',
                'token': t.token,
                'kind': 'activity',
                'session': session,
                'state': live,
                'collapse': session,
              }
            : {'token': t.token, 'kind': 'liveactivity', 'event': state == 'ended' ? 'end' : 'update', 'state': live},
      );
      // An Android token is the phone's: gone, it follows no session any more.
      if (status == 410) {
        _store
          ..activityTokens.removeWhere((a) => a.token == t.token)
          ..save();
      } else if (status != null && status >= 200 && status < 300) {
        sent++;
      }
    }
    // An ended activity takes no more pushes.
    if (state == 'ended') {
      _store
        ..activityTokens.removeWhere((t) => t.session == session)
        ..save();
    }
    return sent;
  }

  void _pushToken(Object? token, String platform) {
    if (platform == 'android') {
      if (token is! String || !_fcmToken.hasMatch(token)) throw _bad('token must be the FCM registration token.');
    } else if (!_apnsToken(token, 200)) {
      throw _bad('token must be the APNs device token (hex).');
    }
  }

  // Validation and answers.

  /// APNs tokens are hex; a Live Activity's is longer than a device's.
  static bool _apnsToken(Object? v, int max) => v is String && RegExp('^[0-9a-f]{64,$max}\$').hasMatch(v);

  static bool _isSessionKey(Object? v) => v is String && _sessionKey.hasMatch(v);

  /// A sealed notification: base64 of nonce 12, ciphertext and tag 16, at least one byte of text.
  static bool _sealed(Object? v) {
    if (v is! String || v.length > _maxEnc) return false;
    try {
      return base64.decode(v).length > 12 + 16;
    } on FormatException {
      return false;
    }
  }

  static String _platform(Map<String, dynamic> body, Set<String> allowed) {
    final p = body['platform'];
    if (p is! String || !allowed.contains(p)) throw _bad('platform must be ${allowed.join(', ')}.');
    return p;
  }

  static String _label(Map<String, dynamic> body) => body['label'] is String ? _clip(body['label'] as String, 80) : '';

  /// [s] cut to at most [max] UTF-16 units, never through a character.
  static String _clip(String s, int max) {
    if (s.length <= max) return s;
    final last = s.codeUnitAt(max - 1);
    return s.substring(0, last >= 0xD800 && last <= 0xDBFF ? max - 1 : max);
  }

  /// The JSON object in [req]'s body (`{}` when empty), at most [maxJsonBytes].
  static Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    if (req.contentLength > maxJsonBytes) {
      req.response.persistentConnection = false;
      throw _Fail(413, 'too_large', 'A request body is at most $maxJsonBytes bytes.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req) {
      bytes.add(chunk);
      if (bytes.length > maxJsonBytes) {
        req.response.persistentConnection = false;
        throw _Fail(413, 'too_large', 'A request body is at most $maxJsonBytes bytes.');
      }
    }
    if (bytes.isEmpty) return {};
    try {
      final body = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (body is Map<String, dynamic>) return body;
    } on FormatException {
      // Answered below.
    }
    throw _bad('The body must be a JSON object.');
  }

  static Future<void> _json(HttpRequest req, int status, Object body) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await req.response.close();
  }
}
