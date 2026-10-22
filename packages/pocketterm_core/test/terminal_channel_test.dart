import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal.dart' show TerminalException;
import 'package:pocketterm_core/terminal_channel.dart';

const _topic = 'abcd1234';

/// A PocketTerm server on loopback as far as the live channel goes
/// (packages/pocketterm_server/PROTOCOL.md): `GET /v1/me`, and `GET /v1/ws`
/// answering joins of [_topic]. It refuses the first [refuse] connections at
/// the door, and can drop or end the one there is.
class _FakeServer {
  _FakeServer({this.refuse = 0, this.at = 0});

  /// The port to take; 0: any free one.
  final int at;

  int refuse;
  late final HttpServer _http;
  late WebSocket _ws;

  /// Joins so far, as they arrive.
  final joins = StreamController<int>.broadcast();
  int joinCount = 0;

  /// What the client sent on the topic.
  final sent = <({String event, Map<String, dynamic> payload})>[];

  int get port => _http.port;

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, at);
    _http.listen((req) async {
      final authorized = req.headers.value('authorization') == 'Bearer token-1';
      if (req.uri.path == '/v1/me') {
        req.response.statusCode = authorized ? 200 : 401;
        req.response.write(
          jsonEncode({
            'device': {'id': 'dev0000000000001', 'role': 'phone', 'label': 'iPhone', 'platform': 'ios'},
            'server': {'id': 'srv0000000000001'},
          }),
        );
        await req.response.close();
        return;
      }
      if (req.uri.path != '/v1/ws' || !authorized || refuse > 0) {
        refuse--;
        req.response.statusCode = 401;
        await req.response.close();
        return;
      }
      final ws = _ws = await WebSocketTransformer.upgrade(req);
      ws.listen((data) {
        final frame = jsonDecode(data as String) as Map<String, dynamic>;
        switch (frame) {
          case {'t': 'join', 'topic': _topic}:
            joinCount++;
            ws.add(jsonEncode({'t': 'joined', 'topic': _topic}));
            joins.add(joinCount);
          case {'t': 'send', 'topic': _topic, 'event': final String event, 'payload': final Map<String, dynamic> p}:
            sent.add((event: event, payload: p));
          case {'t': 'ping'}:
            ws.add(jsonEncode({'t': 'pong'}));
        }
      });
    });
  }

  /// Relays [payload] of [event] to the client, as from another device.
  void deliver(String event, Map<String, dynamic> payload) =>
      _ws.add(jsonEncode({'t': 'msg', 'topic': _topic, 'event': event, 'payload': payload}));

  /// Closes the connection there is with [code]: 1001 the server stopping,
  /// 4003 this device revoked.
  Future<void> drop(int code) => _ws.close(code);

  Future<void> stop() async {
    await joins.close();
    await _http.close(force: true);
  }
}

void main() {
  late _FakeServer server;
  late PocketTermServerClient client;
  late TerminalChannel channel;
  late List<bool> states;
  late List<Map<String, dynamic>> received;
  final key = ChannelKey(List.filled(32, 3));

  /// The computer's side of the topic, sealing what [_FakeServer.deliver] relays.
  final computer = ChannelSeal(key, _topic);

  Future<void> setUpServer({int refuse = 0}) async {
    server = _FakeServer(refuse: refuse);
    await server.start();
    final backend = Backend(url: 'http://127.0.0.1:${server.port}');
    final tokens = MemoryDeviceTokens()
      ..value = jsonEncode({
        'url': backend.url,
        'token': 'token-1',
        'server': 'srv0000000000001',
        'device': {'id': 'dev0000000000001', 'role': 'phone', 'label': 'iPhone', 'platform': 'ios'},
      });
    client = PocketTermServerClient(backend, tokens: tokens);
    expect(await client.restore(), isFalse);
    states = [];
    received = [];
    channel = TerminalChannel(
      client,
      _topic,
      {'state': received.add},
      key: key,
      name: 'test',
      onJoined: ({required joined}) => states.add(joined),
    );
  }

  Future<void> joined(int count) =>
      server.joins.stream.firstWhere((n) => n >= count).timeout(const Duration(seconds: 10));

  Future<void> until(bool Function() check) async {
    for (var i = 0; i < 500 && !check(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(check(), isTrue);
  }

  tearDown(() async {
    await channel.close();
    client.close();
    await server.stop();
  });

  test('a connection the server drops is made again, and messages reach it after', () async {
    await setUpServer();
    channel.open();
    await joined(1);
    await until(() => channel.joined);

    await server.drop(1001);
    await until(() => !channel.joined);
    await joined(2);
    await until(() => channel.joined);
    expect(states, [true, false, true]);

    server.deliver('state', await computer.seal('state', {'windows': 3}));
    await until(() => received.isNotEmpty);
    expect(received.single, {'windows': 3});
  });

  test(
    'opened messages reach the handler in the order they came; unsealed ones never do; sent ones go sealed',
    () async {
      await setUpServer();
      channel.open();
      await until(() => channel.joined);

      server.deliver('state', {'windows': 99});
      for (var i = 0; i < 20; i++) {
        server.deliver('state', await computer.seal('state', {'windows': i}));
      }
      await until(() => received.length == 20);
      expect([for (final m in received) m['windows']], List.generate(20, (i) => i));

      await channel.send('hello', {'from': 'phone'});
      await until(() => server.sent.isNotEmpty);
      final (:event, :payload) = server.sent.single;
      expect(payload.keys, unorderedEquals(['v', 'n', 'c']), reason: 'the server sees only the envelope');
      expect(await computer.open(event, payload), {'from': 'phone'});
    },
  );

  test('a connection refused at the door is tried again until it is let in', () async {
    await setUpServer(refuse: 2);
    channel.open();
    await joined(1);
    await until(() => channel.joined);
    expect(states, [true]);
    expect(client.account, isNotNull, reason: 'the token itself still works');
  });

  test('after close nothing joins again', () async {
    await setUpServer();
    channel.open();
    await joined(1);
    await channel.close();
    await server.drop(1001);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(server.joinCount, 1);
    expect(channel.joined, isFalse);
  });

  test('a message too big for the server is refused before it goes; the connection and later messages stay', () async {
    await setUpServer();
    channel.open();
    await until(() => channel.joined);

    await expectLater(
      channel.send('run', {'text': 'x' * (200 * 1024)}),
      throwsA(isA<TerminalException>()),
      reason: 'sealed and in base64 it would be over 256 KiB, which closes the socket',
    );
    await channel.send('run', {'text': 'small'});
    await until(() => server.sent.isNotEmpty);
    expect(await computer.open('run', server.sent.single.payload), {'text': 'small'});
    expect(states, [true], reason: 'never dropped');
  });

  test('a sender whose clock is far off is told apart: how far, until one of its messages opens again', () async {
    final now = DateTime.now();
    var skew = const Duration(minutes: 12);
    final phone = ChannelSeal(key, _topic, clock: () => DateTime.now().add(skew));
    final mac = ChannelSeal(key, _topic, clock: DateTime.now);
    expect(await mac.open('hello', await phone.seal('hello', {'from': 'p'})), isNull);
    expect(mac.clockOff!.inMinutes, 12);
    skew = const Duration(minutes: -30);
    expect(await mac.open('hello', await phone.seal('hello', {'from': 'p'})), isNull);
    expect(mac.clockOff!.inMinutes, -30);
    skew = Duration.zero;
    expect(await mac.open('hello', await phone.seal('hello', {'from': 'p'})), {'from': 'p'});
    expect(mac.clockOff, isNull);
    // A message from before the receiver started is old, not off.
    final early = ChannelSeal(key, _topic, clock: () => now.subtract(const Duration(seconds: 30)));
    final late = ChannelSeal(key, _topic, clock: DateTime.now);
    expect(await late.open('hello', await early.seal('hello', {})), isNull);
    expect(late.clockOff, isNull);
  });

  test('a close for a revoked device ends the sign-in, and nothing joins again', () async {
    await setUpServer();
    var ended = false;
    client.ended.listen((_) => ended = true);
    channel.open();
    await joined(1);
    await server.drop(4003);
    await until(() => ended);
    expect(client.account, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(server.joinCount, 1);
    expect(channel.joined, isFalse);
  });

  test('a server that goes away reads as unreachable until the channel is let in again', () async {
    await setUpServer();
    var told = 0;
    channel = TerminalChannel(client, _topic, {}, key: key, name: 'test', onUnreachable: () => told++)..open();
    await joined(1);
    expect(channel.unreachable, isFalse);

    final port = server.port;
    // Upgraded sockets outlive the listener: the connection goes too.
    await server.stop();
    await server.drop(1001);
    await until(() => channel.unreachable);
    expect(channel.joined, isFalse);

    server = _FakeServer(at: port);
    await server.start();
    for (var i = 0; i < 150 && !channel.joined; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(channel.joined, isTrue);
    expect(channel.unreachable, isFalse);
    expect(told, 2, reason: 'once when it went, once when it came back');

    await channel.close();
    expect(channel.unreachable, isFalse, reason: 'closed, nothing is tried');
  });
}
