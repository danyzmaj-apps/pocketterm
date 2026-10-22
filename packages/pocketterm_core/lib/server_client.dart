import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:uuid/uuid.dart';

/// What a device is to its server.
enum DeviceRole { desktop, phone }

/// A computer or phone signed in to the server (packages/pocketterm_server/PROTOCOL.md, Device).
@immutable
class Device {
  const Device({
    required this.id,
    required this.role,
    required this.label,
    required this.platform,
    this.seenAt,
    this.current = false,
  });

  factory Device.fromJson(Map<String, dynamic> j) => Device(
    id: j['id'] as String,
    role: j['role'] == 'phone' ? DeviceRole.phone : DeviceRole.desktop,
    label: j['label'] as String? ?? '',
    platform: j['platform'] as String? ?? '',
    seenAt: DateTime.tryParse(j['seen_at'] as String? ?? ''),
    current: j['current'] == true,
  );

  /// 16 characters, made by the server.
  final String id;
  final DeviceRole role;
  final String label;

  /// `macos`, `windows`, `linux`, `ios` or `android`.
  final String platform;
  final DateTime? seenAt;

  /// It's the device asking (GET /v1/devices).
  final bool current;

  Map<String, dynamic> toJson() => {'id': id, 'role': role.name, 'label': label, 'platform': platform};
}

/// This device, signed in to its server: what's kept per server is keyed on
/// [id], the server's own id, which never changes.
@immutable
class Account {
  const Account({required this.id, required this.device});

  /// The server's id (GET /v1/me).
  final String id;

  /// This device, as the server knows it.
  final Device device;
}

/// Where a device keeps its sign-in (the device token and what came with
/// it, one string): the Keychain or a DPAPI-encrypted file in %APPDATA% on a computer, the
/// phone's own secure storage (Native.deviceToken).
abstract interface class DeviceTokens {
  Future<String?> read();

  /// Null forgets it.
  Future<void> write(String? value);
}

/// A sign-in that lasts as long as the app runs (tests, a computer's own
/// built-in server).
class MemoryDeviceTokens implements DeviceTokens {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String? value) async => this.value = value;
}

/// What the server answered instead (`{error, message}`), or that it
/// couldn't be reached ([status] 0). [message] is worded for the person.
class ServerException implements Exception {
  const ServerException(this.status, this.code, this.message);
  final int status;

  /// The server's `error` (`invalid_code`, `unauthorized`, …; `offline`).
  final String code;
  final String message;

  @override
  String toString() => message;
}

/// The PocketTerm server (packages/pocketterm_server/PROTOCOL.md) through
/// this device's token: signing in, pairing, the computers list, images and
/// push. Signed in is having a token ([account]); once the server refuses it
/// (the device was revoked or left, the server was erased) it is forgotten
/// and [ended] says so. The live channel is lib/terminal_channel.dart.
class PocketTermServerClient {
  PocketTermServerClient(this.backend, {required this.tokens});

  final Backend backend;

  /// Where this device's sign-in is kept.
  final DeviceTokens tokens;
  HttpClient _http = _newHttp();
  static HttpClient _newHttp() => HttpClient()..connectionTimeout = const Duration(seconds: 8);

  /// Back at the front: the next requests go on new connections. The ones
  /// kept open from before may be dead without having said so (the system
  /// stops an app's network in the background, the phone changed networks),
  /// and a request on one would wait out its whole timeout. Requests under
  /// way finish where they are.
  void freshConnections() {
    final old = _http;
    _http = _newHttp();
    old.close();
  }

  static const _timeout = Duration(seconds: 20);

  /// This device, signed in; null while signed out.
  Account? get account => _account;
  Account? _account;
  String? _token;

  /// The sign-in as kept in [tokens], so an unchanged one isn't written again.
  String? _kept;

  /// The server refused this device's token: it's signed out here now.
  Stream<void> get ended => _ended.stream;
  final _ended = StreamController<void>.broadcast();

  /// Reads the sign-in this device kept for this server: [account] at once,
  /// without asking the server ([recheck] does), so a launch shows what it
  /// had before the network answers.
  Future<void> load() async {
    try {
      final raw = await tokens.read();
      final saved = jsonDecode(raw ?? 'null');
      if (saved
          case {
            'url': final String url,
            'token': final String token,
            'server': final String server,
            'device': final Map<String, dynamic> device,
          }
          when url == backend.url) {
        _token = token;
        _account = Account(id: server, device: Device.fromJson(device));
        _kept = raw;
      }
    } on Object catch (e) {
      debugPrint('PocketTerm: sign-in not read: $e');
    }
  }

  /// Asks the server whether the sign-in still holds, and keeps what it says
  /// of this device. A refusal ends it ([ended]); no answer (offline), or
  /// one this app doesn't read (a captive portal's page), keeps it.
  Future<void> recheck() async {
    final token = _token;
    if (token == null) return;
    try {
      final me = await _json('GET', '/v1/me', token: token);
      // Signed out, or in anew, meanwhile: the answer is about a sign-in that's gone.
      if (_token == token) await _keep(token, me);
    } on ServerException catch (e) {
      if (e.status == 401 && _token == token) await refused();
    } on Object catch (e) {
      debugPrint('PocketTerm: sign-in not checked: $e');
    }
  }

  /// Signs this computer in with the server's setup token (its setup link).
  Future<Account> redeemSetup(String setup, {required String label, required String platform}) =>
      _redeem('/v1/setup/redeem', {'setup': setup, 'label': label, 'platform': platform});

  /// Signs this phone in with a computer's pairing code (its QR).
  Future<Account> redeemCode(String code, {required String label, required String platform}) =>
      _redeem('/v1/pair/redeem', {'code': code, 'label': label, 'platform': platform});

  Future<Account> _redeem(String path, Map<String, Object> body) async {
    final answer = await _json('POST', path, body: body, auth: false);
    if (answer case {'token': final String token}) return await _signedIn(token);
    throw const ServerException(500, 'internal', "The server didn't send a sign-in.");
  }

  /// Asks the server who [token] is and keeps it.
  Future<Account> _signedIn(String token) async => await _keep(token, await _json('GET', '/v1/me', token: token));

  /// [token] and the device the server's GET /v1/me ([me]) says it is.
  Future<Account> _keep(String token, Object? me) async {
    if (me case {'device': final Map<String, dynamic> device, 'server': {'id': final String server}}) {
      final account = Account(id: server, device: Device.fromJson(device));
      final kept = jsonEncode({
        'url': backend.url,
        'token': token,
        'server': server,
        'device': account.device.toJson(),
      });
      if (kept != _kept) await tokens.write(kept);
      _kept = kept;
      _token = token;
      return _account = account;
    }
    throw const ServerException(500, 'internal', "The server sent an answer this app doesn't read.");
  }

  /// Leaves the server: the token stops working there (DELETE
  /// /v1/devices/me) and is forgotten here, also when the server can't be
  /// reached.
  Future<void> leave() async {
    try {
      if (_token != null) await _json('DELETE', '/v1/devices/me');
    } finally {
      await _forget();
    }
  }

  /// Computer only: wipes everything on the server (every device, this one
  /// too, the computers list, codes, push tokens, images). Its setup link
  /// and id stay.
  Future<void> erase() async {
    await _json('POST', '/v1/erase');
    await _forget();
  }

  Future<void> _forget() async {
    _token = null;
    _account = null;
    _kept = null;
    await tokens.write(null);
  }

  /// The server refused the token (an answer 401, the live channel closed
  /// with 4003): forgotten here, [ended] says so (unless [close]d by then).
  Future<void> refused() async {
    if (_token == null) return;
    await _forget();
    if (!_ended.isClosed) _ended.add(null);
  }

  /// Computer only: a pairing code for a phone, good once for 10 minutes.
  Future<String> createPairingCode() async {
    final answer = await _json('POST', '/v1/pair');
    if (answer case {'code': final String code}) return code;
    throw const ServerException(500, 'internal', "The server didn't send a code.");
  }

  /// Every computer and phone signed in to the server, oldest first.
  Future<List<Device>> devices() async => [
    for (final d in ((await _json('GET', '/v1/devices'))! as List).cast<Map<String, dynamic>>()) Device.fromJson(d),
  ];

  /// Computer only: signs device [id] out (a lost phone); it's told so the
  /// next time it asks.
  Future<void> revokeDevice(String id) => _json('DELETE', '/v1/devices/$id');

  /// The computers phones list, most recently seen first.
  Future<List<Map<String, dynamic>>> desktops() async =>
      ((await _json('GET', '/v1/desktops'))! as List).cast<Map<String, dynamic>>();

  /// Computer only: lists computer [id] (also stamps it seen now).
  Future<void> putDesktop(String id, {required String name, required String platform}) =>
      _json('PUT', '/v1/desktops/$id', body: {'name': name, 'platform': platform});

  Future<void> deleteDesktop(String id) => _json('DELETE', '/v1/desktops/$id');

  /// A new path for an image or file: the phone seals it for this path first.
  String newBlobPath() => const Uuid().v4();

  /// [path] can be one of [newBlobPath]'s.
  static bool isBlobPath(String path) => RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(path);

  /// The most a blob may hold (the server's limit, 20 MiB).
  static const int maxBlobBytes = 20 * 1024 * 1024;

  /// Uploads [bytes] to [path]. One over [maxBlobBytes] fails here, with the
  /// reason: sent, the server would cut it off and the reason would be lost.
  Future<void> putBlob(String path, Uint8List bytes) async {
    if (bytes.length > maxBlobBytes) {
      throw const ServerException(413, 'too_large', 'That file is too large: the most is 20 MB.');
    }
    await _json('PUT', '/v1/blobs/$path', bytes: bytes);
  }

  /// The blob at [path]; the server deletes it once sent.
  Future<Uint8List> getBlob(String path) async => (await _send('GET', '/v1/blobs/$path')).bytes;

  Future<void> deleteBlob(String path) => _json('DELETE', '/v1/blobs/$path');

  /// Push [action] (register, unregister, notify, activity_register,
  /// activity_end, activity) with its [body]; the server's answer
  /// (`{sent}` for notify and activity).
  Future<Map<String, dynamic>> push(String action, Map<String, Object?> body) async =>
      ((await _json('POST', '/v1/push/$action', body: body))! as Map).cast<String, dynamic>();

  /// The live channel's WebSocket, signed in as this device.
  Future<WebSocket> connectSocket() {
    final token = _token;
    if (token == null) throw const ServerException(401, 'unauthorized', 'Not signed in.');
    final url = Uri.parse(backend.url);
    return WebSocket.connect(
      url.replace(scheme: url.scheme == 'https' ? 'wss' : 'ws', path: '/v1/ws').toString(),
      headers: {'authorization': 'Bearer $token'},
    ).timeout(_timeout);
  }

  void close() {
    _http.close(force: true);
    unawaited(_ended.close());
  }

  Future<Object?> _json(
    String method,
    String path, {
    Map<String, Object?>? body,
    Uint8List? bytes,
    bool auth = true,
    String? token,
  }) async {
    final res = await _send(method, path, body: body, bytes: bytes, auth: auth, token: token);
    return res.bytes.isEmpty ? null : jsonDecode(utf8.decode(res.bytes));
  }

  Future<({int status, Uint8List bytes})> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    Uint8List? bytes,
    bool auth = true,
    String? token,
  }) async {
    final bearer = token ?? _token;
    if (auth && bearer == null) throw const ServerException(401, 'unauthorized', 'Not signed in.');
    final ({int status, Uint8List bytes}) res;
    try {
      final req = await _http.openUrl(method, Uri.parse('${backend.url}$path')).timeout(_timeout);
      if (auth) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      if (bytes != null) {
        req
          ..headers.contentType = ContentType.binary
          ..contentLength = bytes.length
          ..add(bytes);
      } else if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final answer = await req.close().timeout(_timeout);
      final b = BytesBuilder(copy: false);
      await answer.forEach(b.add).timeout(_timeout);
      res = (status: answer.statusCode, bytes: b.takeBytes());
    } on Object catch (e) {
      debugPrint('PocketTerm: $method $path: $e');
      throw ServerException(0, 'offline', backend.unreachable);
    }
    if (res.status < 400) return res;
    var code = 'internal';
    var message = 'The server failed (${res.status}).';
    try {
      if (jsonDecode(utf8.decode(res.bytes)) case {'error': final String c, 'message': final String m}) {
        code = c;
        message = m;
      }
    } on FormatException {
      // Not the server's own answer (a proxy's error page).
    }
    // The token this device holds stopped working.
    if (res.status == 401 && auth && token == null) await refused();
    throw ServerException(res.status, code, message);
  }
}
