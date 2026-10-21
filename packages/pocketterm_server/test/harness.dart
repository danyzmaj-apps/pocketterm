import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pocketterm_server/pocketterm_server.dart';

/// An answer from the server: status, headers and the body as JSON (null when it isn't) and bytes.
class Res {
  Res(this.status, this.headers, this.bytes);

  final int status;
  final HttpHeaders headers;
  final List<int> bytes;

  Object? get json {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> get map => json! as Map<String, dynamic>;
  List<dynamic> get list => json! as List<dynamic>;
  String? get error => (json as Map<String, dynamic>?)?['error'] as String?;
}

/// A push relay that records what it's sent and answers each token with [statusFor] (default 200).
class FakeRelay {
  FakeRelay._(this._http) {
    _http.listen((req) async {
      final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
      received.add(body);
      req.response.statusCode = statusFor[body['token']] ?? 200;
      await req.response.close();
    });
  }

  static Future<FakeRelay> start() async => FakeRelay._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _http;
  final List<Map<String, dynamic>> received = [];
  final Map<String, int> statusFor = {};

  Uri get url => Uri.parse('http://127.0.0.1:${_http.port}/relay');

  Future<void> stop() => _http.close(force: true);
}

/// A server on an ephemeral port in a temporary directory, with a fake relay and a clock tests move.
class Harness {
  Harness._(this.dir, this.relay);

  static Future<Harness> start() async {
    final h = Harness._(await Directory.systemTemp.createTemp('pocketterm_server_test'), await FakeRelay.start());
    await h.restart();
    return h;
  }

  final Directory dir;
  final FakeRelay relay;
  final HttpClient _client = HttpClient();
  late PocketTermServer server;
  DateTime now = DateTime.now();
  bool _running = false;

  /// Stops the server if it runs and starts a new one on the same data directory.
  Future<void> restart() async {
    if (_running) await server.stop();
    server = await PocketTermServer.start(
      dataDir: dir,
      address: InternetAddress.loopbackIPv4,
      port: 0,
      publicUrl: Uri.parse('https://pt.example.com/'),
      relay: relay.url,
      clock: () => now,
    );
    _running = true;
  }

  Future<void> close() async {
    if (_running) await server.stop();
    _client.close(force: true);
    await relay.stop();
    await dir.delete(recursive: true);
  }

  Uri url(String path) => server.url.replace(path: path);

  Future<Res> call(
    String method,
    String path, {
    String? token,
    Object? body,
    List<int>? bytes,
    Map<String, String> headers = const {},
  }) async {
    final req = await _client.openUrl(method, url(path));
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    headers.forEach(req.headers.set);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    } else if (bytes != null) {
      req
        ..contentLength = bytes.length
        ..add(bytes);
    }
    final res = await req.close();
    final out = await res.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    return Res(res.statusCode, res.headers, out);
  }

  /// The setup token of the current setup link.
  String get setupToken => server.setupLink().queryParameters['setup']!;

  /// A new computer's device token (and its device id as `.id`).
  Future<({String token, String id})> desktop([String label = 'Mac']) async {
    final res = await call(
      'POST',
      '/v1/setup/redeem',
      body: {'setup': setupToken, 'label': label, 'platform': 'macos'},
    );
    if (res.status != 200) throw StateError('setup redeem: ${res.status} ${utf8.decode(res.bytes)}');
    return (token: res.map['token'] as String, id: (res.map['device'] as Map)['id'] as String);
  }

  /// A new phone paired through a code from computer [desktopToken].
  Future<({String token, String id})> phone(String desktopToken, [String label = 'Phone']) async {
    final code = (await call('POST', '/v1/pair', token: desktopToken)).map['code'] as String;
    final res = await call('POST', '/v1/pair/redeem', body: {'code': code, 'label': label, 'platform': 'ios'});
    if (res.status != 200) throw StateError('pair redeem: ${res.status} ${utf8.decode(res.bytes)}');
    return (token: res.map['token'] as String, id: (res.map['device'] as Map)['id'] as String);
  }

  Future<Socket> socket(String token) async {
    final ws = await WebSocket.connect(
      url('/v1/ws').replace(scheme: 'ws').toString(),
      headers: {'authorization': 'Bearer $token'},
    );
    return Socket(ws);
  }
}

/// A WebSocket client reading frames one at a time.
class Socket {
  Socket(this.ws) {
    ws.listen(
      (data) => _push(jsonDecode(data as String) as Map<String, dynamic>),
      onDone: () => _done.complete(ws.closeCode),
    );
  }

  final WebSocket ws;
  final List<Map<String, dynamic>> _frames = [];
  final List<Completer<Map<String, dynamic>>> _waiting = [];
  final Completer<int?> _done = Completer();

  /// The close code once the server closes it.
  Future<int?> get closed => _done.future.timeout(const Duration(seconds: 5));

  void _push(Map<String, dynamic> frame) {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete(frame);
    } else {
      _frames.add(frame);
    }
  }

  /// The next frame (fails after 5 seconds without one).
  Future<Map<String, dynamic>> next() {
    if (_frames.isNotEmpty) return Future.value(_frames.removeAt(0));
    final c = Completer<Map<String, dynamic>>();
    _waiting.add(c);
    return c.future.timeout(const Duration(seconds: 5));
  }

  void send(Map<String, dynamic> frame) => ws.add(jsonEncode(frame));

  /// Joins [topic] and waits for the server's ack.
  Future<void> join(String topic) async {
    send({'t': 'join', 'topic': topic});
    final ack = await next();
    if (ack['t'] != 'joined' || ack['topic'] != topic) throw StateError('join $topic: $ack');
  }

  Future<void> close() => ws.close();
}
