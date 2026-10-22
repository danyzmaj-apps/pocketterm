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

/// The most one device's blobs (those waiting and those arriving) may take together (200 MiB); past it an upload
/// gets 429.
const int maxDeviceBlobBytes = 200 * 1024 * 1024;

/// The most all blobs may take together (1 GiB); past it an upload gets 507.
const int maxTotalBlobBytes = 1024 * 1024 * 1024;

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

/// A session as phones and the push endpoints name it: `<desktop id>/<key>` (lib/live.dart's routedKey).
final _routedKey = RegExp(r'^[a-z0-9]{8}/[\w.:/-]{1,55}$');
final _fcmToken = RegExp(r'^[A-Za-z0-9_:\-]{100,4096}$');

/// What a push names its computer by (pocketterm_core's pushTag): 8 bytes of an HMAC under its key, base64url.
final _pushTag = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// What a push names a coding session by (pocketterm_core's sessionTag): 16 bytes of an HMAC, base64url.
final _sessionTag = RegExp(r'^[A-Za-z0-9_-]{22}$');

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

/// What the redeem throttle counts [address] as: itself, an IPv4-mapped IPv6 address as its IPv4 one, any other
/// IPv6 address as its /64 (`2001:db8:1:2::/64`).
String callerKey(String address) {
  final ip = InternetAddress.tryParse(address);
  if (ip == null || ip.type != InternetAddressType.IPv6) return address;
  final b = ip.rawAddress;
  if (b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff) return b.sublist(12).join('.');
  final groups = [for (var i = 0; i < 8; i += 2) ((b[i] << 8) | b[i + 1]).toRadixString(16)];
  return '${groups.join(':')}::/64';
}

/// PocketTerm's own server for one owner: devices, pairing, desktops, blobs, push forwarding and the live
/// channel over WebSocket. Everything it keeps lives in one data directory. See PROTOCOL.md.
class PocketTermServer {
  PocketTermServer._(
    this._dir,
    this._http,
    this._store,
    this.publicUrl,
    this._now,
    this._trustProxy,
    this._trustLoopbackProxy,
    this._log,
    Uri relay,
    List<int> relayKey,
    Duration relayRetry,
    this._deviceBlobQuota,
    this._blobQuota,
  ) {
    _relay = Relay(relay, relayKey, log: _log, onGone: _gone, firstRetry: relayRetry);
  }

  /// Starts serving on [address]:[port] (0 picks a free port; see [port]). [publicUrl] is the address phones
  /// and computers reach it at, put in setup links. [relay] is the push relay and [relayKey] its X25519 public
  /// key, which every push is sealed to (default: the publisher's relay and key).
  /// With [trustProxy], the caller's address for rate limits is the last one in X-Forwarded-For (set it only
  /// behind a reverse proxy). With [trustLoopbackProxy], it is trusted only from a loopback peer: for a server on
  /// 127.0.0.1 that `tailscale serve` publishes, so each tailnet caller gets its own throttle. [clock] stands in
  /// for the time and [relayRetry] for the relay's first retry wait in tests. [deviceBlobQuota] and [blobQuota]
  /// stand in for [maxDeviceBlobBytes] and [maxTotalBlobBytes].
  ///
  /// Throws [StorageException] when [dataDir] can't be written, is held by another server or its state.json
  /// doesn't read (see [Store.open]).
  static Future<PocketTermServer> start({
    required Directory dataDir,
    required InternetAddress address,
    required int port,
    required Uri publicUrl,
    Uri? relay,
    List<int>? relayKey,
    bool trustProxy = false,
    bool trustLoopbackProxy = false,
    void Function(String message)? log,
    DateTime Function()? clock,
    Duration relayRetry = const Duration(seconds: 2),
    int deviceBlobQuota = maxDeviceBlobBytes,
    int blobQuota = maxTotalBlobBytes,
  }) async {
    final store = Store.open(dataDir, log: log);
    final HttpServer http;
    try {
      Store.setupToken(dataDir);
      Directory('${dataDir.path}/blobs').createSync(recursive: true);
      http = await HttpServer.bind(address, port);
    } on Object {
      store.close();
      rethrow;
    }
    final server = PocketTermServer._(
      dataDir,
      http,
      store,
      publicUrl,
      clock ?? DateTime.now,
      trustProxy,
      trustLoopbackProxy,
      log,
      relay ?? defaultRelay,
      relayKey ?? parseRelayKey(defaultRelayKey)!,
      relayRetry,
      deviceBlobQuota,
      blobQuota,
    ).._countBlobs();
    server._sweeper = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(server.sweep()));
    unawaited(server.sweep());
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
  late final Relay _relay;
  final Hub _hub = Hub();
  final DateTime Function() _now;
  final bool _trustProxy;
  final bool _trustLoopbackProxy;
  final Map<String, List<DateTime>> _failures = {};
  final void Function(String)? _log;
  Timer? _sweeper;
  final int _deviceBlobQuota;
  final int _blobQuota;

  /// The size of each blob waiting, by path, and the device that put it (`''` for one from before a restart).
  final Map<String, ({String device, int size})> _blobUse = {};

  /// The bytes of uploads still arriving, by device.
  final Map<String, int> _arriving = {};

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

  /// Stops serving: closes every WebSocket (1001) and the listener, gives pushes on their way a few seconds,
  /// and lets go of the data directory. Stopping again does nothing.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _sweeper?.cancel();
    await _hub.closeAll();
    await _http.close(force: true);
    await _relay.idle(timeout: const Duration(seconds: 3));
    _relay.close();
    _store.close();
  }

  var _stopped = false;

  /// Completes once every push queued so far has been answered by the relay or given up on (tests).
  Future<void> pushesDone() => _relay.idle();

  Directory get _blobs => Directory('${_dir.path}/blobs');

  /// Counts the blobs left from before a restart (anyone's: who put them isn't kept).
  void _countBlobs() {
    for (final f in _blobs.listSync().whereType<File>()) {
      final path = f.uri.pathSegments.last;
      if (_blobPath.hasMatch(path)) _blobUse[path] = (device: '', size: f.lengthSync());
    }
  }

  /// The bytes blobs take on the server, waiting and arriving: all of them, or [device]'s.
  int _blobBytes([String? device]) {
    var sum = 0;
    for (final u in _blobUse.values) {
      if (device == null || u.device == device) sum += u.size;
    }
    for (final MapEntry(key: d, value: n) in _arriving.entries) {
      if (device == null || d == device) sum += n;
    }
    return sum;
  }

  /// Why [device] can't upload [more] bytes now: its own blobs would pass its quota (429; they go once the
  /// computer picks them up, or after [blobTtl]), or all blobs the server's (507). Null when there is room.
  _Fail? _noRoom(String device, int more) {
    if (_blobBytes(device) + more > _deviceBlobQuota) {
      return _Fail(
        429,
        'rate_limited',
        'This device has too many uploads waiting on the server. Try again once your computer has picked them up.',
        retryAfter: const Duration(minutes: 1),
      );
    }
    if (_blobBytes() + more > _blobQuota) {
      return _Fail(507, 'storage_full', 'The server has no room for more uploads right now. Try again in a while.');
    }
    return null;
  }

  /// Deletes blob [file] (at [path]) and stops counting it.
  void _dropBlob(File file, String path) {
    _blobUse.remove(path);
    if (file.existsSync()) file.deleteSync();
  }

  /// Saves the store, or logs why it couldn't: for changes nobody waits on (a seen stamp, housekeeping), which
  /// the next save that works keeps.
  void _trySave() {
    try {
      _store.save();
    } on StorageException catch (e) {
      _log?.call('$e');
    }
  }

  /// The minute's housekeeping, also run at start: forgets blobs past [blobTtl] (and half-written ones), expired
  /// pairing codes and old redeem failures, and ends the Live Activities of every computer that hasn't checked in
  /// for [Desktop.activitiesFor].
  Future<void> sweep() async {
    final now = _now();
    try {
      for (final f in _blobs.listSync().whereType<File>()) {
        if (now.difference(f.lastModifiedSync()) > blobTtl) _dropBlob(f, f.uri.pathSegments.last);
      }
    } on FileSystemException catch (e) {
      _log?.call('blob sweep: $e');
    }
    final before = _store.pairingCodes.length;
    _store.pairingCodes.removeWhere((_, c) => !c.expires.isAfter(now));
    if (_store.pairingCodes.length != before) _trySave();
    _failures
      ..forEach((_, times) => times.removeWhere((t) => now.difference(t) >= redeemWindow))
      ..removeWhere((_, times) => times.isEmpty);
    bool silent(String desktop) {
      final d = _store.desktops[desktop];
      return d == null || now.difference(d.seen) >= Desktop.activitiesFor;
    }

    _store.activityTokens.map((t) => t.desktop).where(silent).toSet().forEach(_endActivities);
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      await _route(req);
    } on _Fail catch (e) {
      if (e.retryAfter != null) req.response.headers.set('retry-after', '${e.retryAfter!.inSeconds + 1}');
      await _json(req, e.status, {'error': e.code, 'message': e.message});
    } on StorageException catch (e) {
      _log?.call('${req.method} ${req.uri.path}: $e');
      try {
        await _json(req, 507, {
          'error': 'storage',
          'message':
              "The server couldn't save this: its disk may be full or its data folder isn't writable. Its log "
              'says which.',
        });
      } on Object {
        // The answer had already started.
      }
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
    if (p.length < 2 || p[0] != 'v1') throw _unknown();
    final m = req.method;
    void only(String method) {
      if (m != method) throw _Fail(405, 'method_not_allowed', '${req.uri.path} takes $method.');
    }

    switch (p.sublist(1)) {
      case ['health']:
        only('GET');
        // time: the server's clock, so an app can tell its own is off (sealed messages more than 5 minutes off
        // are dropped).
        return await _json(req, 200, {
          'pocketterm': protocolVersion,
          'version': serverVersion,
          'time': iso(DateTime.now()),
        });
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
        return await _json(req, 200, await _push(action, await _readJson(req), me));
      case ['ws']:
        only('GET');
        final me = _auth(req);
        if (!WebSocketTransformer.isUpgradeRequest(req)) throw _bad('Expected a WebSocket upgrade.');
        if (_hub.socketsOf(me.id) >= maxSocketsPerDevice) {
          throw _Fail(
            429,
            'rate_limited',
            'This device has $maxSocketsPerDevice live connections open already. Close the app on it and open '
                'it again.',
            retryAfter: const Duration(seconds: 30),
          );
        }
        final ws = await WebSocketTransformer.upgrade(req);
        // Revoked while upgrading.
        if (!_store.devices.containsKey(me.id)) return await ws.close(closeRevoked, 'revoked');
        _hub.add(ws, me.id);
        return;
      default:
        throw _unknown();
    }
  }

  /// An endpoint this server doesn't have: likely an app newer than the server.
  static _Fail _unknown() => _Fail(
    404,
    'not_found',
    'No such endpoint on this server (PocketTerm server $serverVersion). If the app is newer than the server, '
        'update the server.',
  );

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
      _trySave();
    }
    return device;
  }

  Device _desktopOnly(Device d) {
    if (!d.isDesktop) throw _Fail(403, 'forbidden', 'Only a computer can do this.');
    return d;
  }

  /// Who sent [req], for the redeem throttle: the TCP peer, or behind a trusted proxy the address it put last
  /// in X-Forwarded-For (with trustLoopbackProxy, only when the TCP peer is loopback). An IPv6 caller counts by
  /// its /64: one machine or home gets a whole /64, so its addresses would otherwise be fresh counters.
  String _caller(HttpRequest req) {
    final peer = req.connectionInfo?.remoteAddress;
    var caller = peer?.address ?? '';
    if (_trustProxy || (_trustLoopbackProxy && peer != null && peer.isLoopback)) {
      final forwarded = req.headers['x-forwarded-for']?.join(',').split(',').last.trim() ?? '';
      if (forwarded.isNotEmpty) caller = forwarded;
    }
    return callerKey(caller);
  }

  /// Runs [redeem] under the throttle: an address with [maxRedeemFailures] failures in [redeemWindow] waits,
  /// and every 400 counts as a failure.
  Future<void> _redeem(HttpRequest req, Map<String, dynamic> Function(Map<String, dynamic>) redeem) async {
    final ip = _caller(req);
    final now = _now();
    final times = (_failures[ip] ??= [])..removeWhere((t) => now.difference(t) >= redeemWindow);
    if (times.length >= maxRedeemFailures) {
      final wait = redeemWindow - now.difference(times.first);
      final minutes = (wait.inSeconds / 60).ceil();
      throw _Fail(
        429,
        'rate_limited',
        'Too many tries from this network. Wait $minutes minute${minutes == 1 ? '' : 's'}, then try again.',
        retryAfter: wait,
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
        "That setup link doesn't work: it was replaced by a newer one. Get the current one with "
            '`pocketterm-server setup-link` on your server, or Add a computer in PocketTerm on the computer that '
            'hosts it.',
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
    _store.devices[id] = device;
    try {
      _store.save();
    } on StorageException {
      // Nobody will ever hold its token.
      _store.devices.remove(id);
      rethrow;
    }
    return {'token': token, 'device': device.toApi()};
  }

  /// Signs device [id] out for good: its token, its push and activity tokens, the pairing codes it made and its
  /// sockets. A computer's desktops go from the list too (nothing checks them in any more); their Live Activities,
  /// and a phone's own, are ended. Throws [StorageException] with nothing changed when that can't be saved.
  void _dropDevice(String id) {
    final desktops = [
      for (final d in _store.desktops.values)
        if (d.device == id) d.id,
    ];
    final own = _store.activityTokens.where((t) => t.device == id).toList();
    _store.change(
      () => _store
        ..devices.remove(id)
        ..desktops.removeWhere((_, d) => d.device == id)
        ..pairingCodes.removeWhere((_, c) => c.by == id)
        ..pushTokens.removeWhere((_, t) => t.device == id)
        ..activityTokens.removeWhere((t) => t.device == id),
    );
    _hub.closeDevice(id);
    _sendActivity(own, _ended(), null, null);
    desktops.forEach(_endActivities);
  }

  /// Erases everything the owner has here: every device (the caller too), computer, pairing code, push and
  /// activity token and blob; every socket closes with 4003. The setup token and the server id stay, so
  /// computers can set up again with the same link. Throws [StorageException] with nothing changed when that
  /// can't be saved.
  Future<void> _erase() async {
    final following = [..._store.activityTokens];
    _store.change(
      () => _store
        ..devices.clear()
        ..desktops.clear()
        ..pairingCodes.clear()
        ..pushTokens.clear()
        ..activityTokens.clear(),
    );
    // Nothing would end the phones' Live Activities afterwards.
    _sendActivity(following, _ended(), null, null);
    _blobUse.clear();
    for (final f in _blobs.listSync()) {
      f.deleteSync(recursive: true);
    }
    await _hub.closeAll(code: closeRevoked, reason: 'erased');
  }

  // Desktops.

  /// Whether computer [me] may change (or speak for) the computer [id] in the list: nobody holds it, [me] does,
  /// or the computer holding it is gone or has stopped checking in (one that signed in again under a new device,
  /// keeping its id, takes it back that way).
  bool _mayHold(String id, Device me) {
    final d = _store.desktops[id];
    final owner = d?.device;
    if (d == null || owner == null || owner == me.id) return true;
    return !_store.devices.containsKey(owner) || _now().difference(d.seen) >= Desktop.onlineFor;
  }

  Future<void> _desktop(HttpRequest req, String id) async {
    final me = _auth(req);
    switch (req.method) {
      case 'PUT':
        _desktopOnly(me);
        if (!_desktopId.hasMatch(id)) throw _bad("The computer's id must be 8 characters a-z, 0-9.");
        final body = await _readJson(req);
        final name = body['name'];
        if (name is! String) throw _bad('name must be a string.');
        final platform = _platform(body, _desktopPlatforms);
        if (!_mayHold(id, me)) throw _Fail(403, 'forbidden', 'Only the computer that added it can change it.');
        final desktop = Desktop(id: id, name: _clip(name, 80), platform: platform, seen: _now(), device: me.id);
        _store.change(() => _store.desktops[id] = desktop);
        return await _json(req, 200, desktop.toApi(_now()));
      case 'DELETE':
        // Only a computer, and only the one that holds it.
        _desktopOnly(me);
        if (!_mayHold(id, me)) throw _Fail(403, 'forbidden', 'Only the computer that added it can remove it.');
        if (_store.desktops.containsKey(id)) _store.change(() => _store.desktops.remove(id));
        _endActivities(id);
        return await _json(req, 200, {'ok': true});
      default:
        throw _Fail(405, 'method_not_allowed', '${req.uri.path} takes PUT or DELETE.');
    }
  }

  // Blobs.

  Future<void> _blob(HttpRequest req, String path) async {
    final me = _auth(req);
    if (!_blobPath.hasMatch(path)) throw _bad('A blob path is 1 to 64 characters A-Z, a-z, 0-9 and -.');
    final file = File('${_blobs.path}/$path');
    switch (req.method) {
      case 'PUT':
        if (file.existsSync()) throw _Fail(409, 'conflict', 'That blob path is taken.');
        if (req.contentLength > maxBlobBytes) {
          req.response.persistentConnection = false;
          throw _tooLargeBlob();
        }
        if (_noRoom(me.id, req.contentLength < 0 ? 0 : req.contentLength) case final full?) {
          req.response.persistentConnection = false;
          throw full;
        }
        final part = File('${_blobs.path}/.$path.${newId(8)}.part');
        var size = 0;
        var counted = 0;
        var tooLarge = false;
        _Fail? full;
        try {
          final sink = part.openWrite();
          try {
            await for (final chunk in req) {
              size += chunk.length;
              if (size > maxBlobBytes) {
                tooLarge = true;
                break;
              }
              // Uploads arriving side by side count together.
              if (_noRoom(me.id, chunk.length) case final f?) {
                full = f;
                break;
              }
              _arriving.update(me.id, (n) => n + chunk.length, ifAbsent: () => chunk.length);
              counted += chunk.length;
              sink.add(chunk);
            }
          } finally {
            await sink.close();
          }
          if (!tooLarge && full == null && !file.existsSync()) part.renameSync(file.path);
        } on Object catch (e) {
          // A full disk, or the phone gone mid-upload: nothing half-written stays.
          _deleteQuietly(part);
          if (e is FileSystemException) {
            throw StorageException("Couldn't save the upload: ${e.osError?.message ?? e.message}.");
          }
          rethrow;
        } finally {
          final left = (_arriving[me.id] ?? 0) - counted;
          if (left > 0) {
            _arriving[me.id] = left;
          } else {
            _arriving.remove(me.id);
          }
        }
        if (tooLarge || full != null) {
          _deleteQuietly(part);
          req.response.persistentConnection = false;
          throw full ?? _tooLargeBlob();
        }
        // Another upload to the same path finished meanwhile.
        if (part.existsSync()) {
          _deleteQuietly(part);
          throw _Fail(409, 'conflict', 'That blob path is taken.');
        }
        _blobUse[path] = (device: me.id, size: size);
        return await _json(req, 201, {'path': path});
      case 'GET':
        if (!file.existsSync()) throw _Fail(404, 'not_found', 'No such blob: it ran out or was downloaded.');
        if (_now().difference(file.lastModifiedSync()) > blobTtl) {
          _dropBlob(file, path);
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
        _dropBlob(file, path);
        return;
      case 'DELETE':
        _dropBlob(file, path);
        return await _json(req, 200, {'ok': true});
      default:
        throw _Fail(405, 'method_not_allowed', '${req.uri.path} takes PUT, GET or DELETE.');
    }
  }

  // Push: sealed notifications and Live Activity states, forwarded to the relay.

  Future<Map<String, dynamic>> _push(String action, Map<String, dynamic> body, Device me) async {
    final device = me.id;
    final platformValue = body['platform'];
    final platform = platformValue ?? 'ios';
    if (platform != 'ios' && platform != 'android') throw _bad('platform must be ios or android.');
    final token = body['token'];
    switch (action) {
      case 'register':
        _pushToken(token, platform as String);
        // A phone has one push token: a new one (Apple or Google replaced it) takes the old one's place, and on
        // Android the sessions it follows move with it (once: the phone may have followed them anew already).
        final old = [
          for (final p in _store.pushTokens.values)
            if (p.device == device && p.token != token) p.token,
        ];
        _store.pushTokens.removeWhere((t, _) => old.contains(t));
        final moved = {
          for (final a in _store.activityTokens)
            if (a.device == device && a.platform == 'android' && old.contains(a.token)) a.session: a.ref,
        };
        _store.activityTokens
          ..removeWhere((a) => a.device == device && a.platform == 'android' && old.contains(a.token))
          ..removeWhere((a) => a.token == token && moved.containsKey(a.session))
          ..addAll([
            for (final MapEntry(key: session, value: ref) in moved.entries)
              ActivityToken(token: token as String, session: session, platform: 'android', device: device, ref: ref),
          ]);
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
        // Turning notifications off: the token (all of this phone's without one) and every Live Activity this
        // phone follows. An Android phone's sessions follow its device token, so a token also takes those.
        _store
          ..pushTokens.removeWhere((t, p) => token is String ? t == token : p.device == device)
          ..activityTokens.removeWhere((t) => t.device == device || t.token == token)
          ..save();
        return {'ok': true};
      case 'notify':
        final tag = body['tag'];
        if (tag is! String || !_pushTag.hasMatch(tag)) throw _bad("tag must be the computer's push tag.");
        final enc = body['enc'];
        if (!_sealed(enc)) throw _bad('enc must be the sealed notification, base64, at most $_maxEnc.');
        final collapse = body['collapse'];
        if (collapse != null && (collapse is! String || !_sessionTag.hasMatch(collapse))) {
          throw _bad("collapse must be the coding session's push tag.");
        }
        return {'sent': _notify(tag, enc! as String, collapse as String?)};
      case 'activity_register':
        final session = body['session'];
        final ref = body['ref'];
        if (platform == 'android') {
          if (token is! String || !_fcmToken.hasMatch(token)) throw _bad('token must be the FCM registration token.');
          if (ref is! String || !_sessionTag.hasMatch(ref)) throw _bad("ref must be the session's push tag.");
        } else if (!_apnsToken(token, 400)) {
          throw _bad("token must be the activity's push token (hex).");
        }
        if (session is! String || !_routedKey.hasMatch(session)) {
          throw _bad('session must be a routed session key, <desktop id>/<key>.');
        }
        // Only a phone that turned notifications on (and so registered its push token) follows sessions: one that
        // turned them off gets nothing through the relay.
        if (!_store.pushTokens.values.any((p) => p.device == device)) {
          throw _Fail(409, 'push_off', 'Notifications are off on this phone: turn them on to follow a session.');
        }
        // An iPhone's activity follows one session for good.
        _store.activityTokens.removeWhere((t) => t.token == token && (t.session == session || platform == 'ios'));
        _store
          ..activityTokens.add(
            ActivityToken(
              token: token! as String,
              session: session,
              platform: platform as String,
              device: device,
              // An iPhone's activity needs none: Apple routes its pushes by the activity's own token.
              ref: platform == 'android' ? ref as String? : null,
            ),
          )
          ..save();
        return {'ok': true};
      case 'activity_end':
        // No session ends every one this token follows; a bad one ends none. Only this device's own.
        final session = body['session'];
        if (session != null && !_isSessionKey(session)) throw _bad('session must be a coding session key.');
        bool ends(ActivityToken t) =>
            t.device == device && t.token == token && (session == null || t.session == session);
        if (_store.activityTokens.any(ends)) _store.change(() => _store.activityTokens.removeWhere(ends));
        return {'ok': true};
      case 'activity':
        final session = body['session'];
        if (session is! String || !_routedKey.hasMatch(session)) {
          throw _bad('session must be a routed session key, <desktop id>/<key>.');
        }
        // Only the computer whose session it is moves its followers' Live Activities.
        _desktopOnly(me);
        if (!_mayHold(session.split('/').first, me)) {
          throw _Fail(403, 'forbidden', 'Only the computer the session runs on can update its Live Activities.');
        }
        final state = body['state'];
        if (!_activityStates.contains(state)) throw _bad('state must be ${_activityStates.join(', ')}.');
        final kind = body['kind'];
        if (kind != null && !_activityKinds.contains(kind)) throw _bad('kind must be ${_activityKinds.join(', ')}.');
        final tag = body['tag'];
        if (tag != null && (tag is! String || !_pushTag.hasMatch(tag))) {
          throw _bad("tag must be the computer's push tag.");
        }
        final enc = body['enc'];
        if (enc != null && (tag == null || !_sealed(enc))) {
          throw _bad('enc must be the sealed state, base64, at most $_maxEnc, with tag.');
        }
        final live = {
          'state': state,
          'since': _now().millisecondsSinceEpoch ~/ 1000,
          if (state == 'needs' && kind != null) 'kind': kind,
        };
        final tokens = _store.activityTokens.where((t) => t.session == session).toList();
        // An ended activity takes no more pushes.
        if (state == 'ended' && tokens.isNotEmpty) {
          _store.change(() => _store.activityTokens.removeWhere((t) => t.session == session));
        }
        return {'sent': _sendActivity(tokens, live, enc as String?, tag as String?)};
      default:
        throw _unknown();
    }
  }

  /// Queues [enc], sealed by the computer whose push tag is [tag], for every phone; the number of phones.
  int _notify(String tag, String enc, String? collapse) {
    final tokens = _store.pushTokens.values.toList();
    for (final t in tokens) {
      _relay.send({
        if (t.platform == 'android') 'platform': 'android',
        'token': t.token,
        'kind': 'terminal',
        'enc': enc,
        'tag': tag,
        // Lets a newer push for the same coding session replace an older one.
        'collapse': ?collapse,
      }, key: collapse == null ? null : 'n|${t.token}|$collapse');
    }
    return tokens.length;
  }

  /// The relay says [token]'s phone is gone: it gets nothing more (an Android phone's token is also the one its
  /// followed sessions use).
  void _gone(String token) {
    final before = _store.pushTokens.length + _store.activityTokens.length;
    _store
      ..pushTokens.remove(token)
      ..activityTokens.removeWhere((a) => a.token == token);
    if (_store.pushTokens.length + _store.activityTokens.length != before) _trySave();
  }

  Map<String, dynamic> _ended() => {'state': 'ended', 'since': _now().millisecondsSinceEpoch ~/ 1000};

  /// Ends every Live Activity following a session of computer [desktop] and forgets their tokens: it signed out,
  /// was removed, or stopped checking in.
  void _endActivities(String desktop) {
    final tokens = _store.activityTokens.where((t) => t.desktop == desktop).toList();
    if (tokens.isEmpty) return;
    _store.activityTokens.removeWhere((t) => t.desktop == desktop);
    _trySave();
    _sendActivity(tokens, _ended(), null, null);
  }

  /// Queues the move of the Live Activities of [tokens] to [live] (ended: ends them); the number queued. An
  /// iPhone gets the state alone at its activity's token (Apple can't hand a Live Activity push to code that would
  /// decrypt it, and its token is all Apple needs); an Android phone gets [enc], the state the computer with push
  /// tag [tag] sealed, or nothing without it, except an end, which says nothing and goes plain. Neither carries a
  /// session key or a computer id: an Android push names its session only by the tag the phone registered (ref).
  int _sendActivity(List<ActivityToken> tokens, Map<String, dynamic> live, String? enc, String? tag) {
    final ended = live['state'] == 'ended';
    var sent = 0;
    for (final t in tokens) {
      final Map<String, dynamic> push;
      if (t.platform != 'android') {
        push = {'token': t.token, 'kind': 'liveactivity', 'event': ended ? 'end' : 'update', 'state': live};
      } else if (t.ref == null) {
        continue; // Registered before sessions had tags: nothing the phone could match.
      } else if (ended) {
        push = {'platform': 'android', 'token': t.token, 'kind': 'activity', 'ref': t.ref, 'state': live};
      } else if (enc != null && tag != null) {
        push = {'platform': 'android', 'token': t.token, 'kind': 'activity', 'enc': enc, 'tag': tag, 'ref': t.ref};
      } else {
        continue;
      }
      // A newer state for the same session replaces one still waiting, and never overtakes one on its way.
      _relay.send(push, key: 'a|${t.token}|${t.session}');
      sent++;
    }
    return sent;
  }

  static _Fail _tooLargeBlob() =>
      _Fail(413, 'too_large', 'That file is too large: the most is ${maxBlobBytes ~/ (1024 * 1024)} MB.');

  void _deleteQuietly(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException catch (e) {
      _log?.call('$e');
    }
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
