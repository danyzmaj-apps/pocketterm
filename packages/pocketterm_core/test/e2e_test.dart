import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/terminal_channel.dart';

void main() {
  final key = ChannelKey(List.generate(32, (i) => i));
  final other = ChannelKey(List.generate(32, (i) => 255 - i));
  const topic = 'abcd1234';

  group('sealed bytes', () {
    test('open with the same key and purpose, and come out as they went in', () async {
      final plain = utf8.encode('a photo, really');
      final sealed = await sealBytes(key, plain, imageAad('u1/x'));
      expect(sealed.length, 12 + plain.length + 16);
      expect(utf8.decode(sealed, allowMalformed: true), isNot(contains('photo')));
      expect(await openBytes(key, sealed, imageAad('u1/x')), plain);
    });

    test('two seals of the same bytes differ (a fresh nonce each time)', () async {
      final a = await sealBytes(key, [1, 2, 3], pushAad('abcd1234'));
      final b = await sealBytes(key, [1, 2, 3], pushAad('abcd1234'));
      expect(a, isNot(b));
    });

    test('a changed byte anywhere (nonce, ciphertext, tag) and they open to nothing', () async {
      final sealed = await sealBytes(key, utf8.encode('hello there'), imageAad('u1/x'));
      for (final i in [0, 11, 12, sealed.length - 17, sealed.length - 1]) {
        final changed = [...sealed]..[i] ^= 1;
        expect(await openBytes(key, changed, imageAad('u1/x')), isNull, reason: 'byte $i');
      }
      expect(await openBytes(key, sealed.sublist(0, 27), imageAad('u1/x')), isNull);
    });

    test('another key, or another purpose, and they open to nothing', () async {
      final sealed = await sealBytes(key, [1, 2, 3], imageAad('u1/x'));
      expect(await openBytes(other, sealed, imageAad('u1/x')), isNull);
      expect(await openBytes(key, sealed, imageAad('u1/y')), isNull, reason: 'moved to another path');
      expect(await openBytes(key, sealed, pushAad('abcd1234')), isNull, reason: 'taken for a push');
    });
  });

  group('envelopes', () {
    test('round trip a JSON object', () async {
      final env = await sealEnvelope(key, {'a': 1, 'b': 'two'}, channelAad(topic, 'state'));
      expect(env.keys, unorderedEquals(['v', 'n', 'c']));
      expect(jsonEncode(env), isNot(contains('two')));
      final opened = await openEnvelope(key, env, channelAad(topic, 'state'));
      expect(opened.message, {'a': 1, 'b': 'two'});
    });

    test('moved to another event or computer, changed, or of another version, they are dropped', () async {
      final env = await sealEnvelope(key, {'a': 1}, channelAad(topic, 'state'));
      expect((await openEnvelope(key, env, channelAad(topic, 'run'))).drop, 'sealed');
      expect((await openEnvelope(key, env, channelAad('zzzz9999', 'state'))).drop, 'sealed');
      final c = base64Decode(env['c'] as String)..[0] ^= 1;
      expect((await openEnvelope(key, {...env, 'c': base64Encode(c)}, channelAad(topic, 'state'))).drop, 'sealed');
      expect((await openEnvelope(key, {...env, 'v': 2}, channelAad(topic, 'state'))).drop, 'version');
      expect((await openEnvelope(key, {'windows': 3}, channelAad(topic, 'state'))).drop, 'version');
      expect((await openEnvelope(key, {...env, 'n': 'not base64!'}, channelAad(topic, 'state'))).drop, 'sealed');
    });
  });

  group('the live channel', () {
    var now = DateTime(2026, 10, 22, 12);
    DateTime clock() => now;
    late ChannelSeal phone;
    late ChannelSeal desktop;
    setUp(() {
      now = DateTime(2026, 10, 22, 12);
      phone = ChannelSeal(key, topic, clock: clock);
      desktop = ChannelSeal(key, topic, clock: clock);
    });

    test('both ways, each side reads what the other sealed, as it was', () async {
      expect(await desktop.open('hello', await phone.seal('hello', {'from': 'p1'})), {'from': 'p1'});
      expect(await phone.open('state', await desktop.seal('state', {'windows': <Object>[]})), {'windows': <Object>[]});
    });

    test(
      "a payload's own seq, ts, mid and ep come through untouched (an items catch-up carries the log's seq)",
      () async {
        final items = {'session': 's1', 'epoch': 'e1', 'seq': 42, 'ts': 7, 'mid': 'm', 'ep': 'x', 'items': <Object>[]};
        expect(await phone.open('items', await desktop.seal('items', items)), items);
      },
    );

    test('the computer takes a phone message once: the server replaying it gets nothing through', () async {
      final wire = await phone.seal('run', {'id': 'r1', 'op': 'send'});
      expect(await desktop.open('run', wire), isNotNull);
      expect(await desktop.open('run', wire), isNull);
      now = now.add(const Duration(minutes: 3));
      expect(await desktop.open('run', wire), isNull, reason: 'still remembered within 10 minutes');
    });

    test('a message more than 5 minutes off the clock is dropped, either way', () async {
      final fromPhone = await phone.seal('hello', {'from': 'p1'});
      final fromDesktop = await desktop.seal('state', {'windows': 1});
      now = now.add(const Duration(minutes: 5, seconds: 1));
      expect(await desktop.open('hello', fromPhone), isNull);
      expect(await phone.open('state', fromDesktop), isNull);
    });

    test('a message sealed with another computer key is dropped', () async {
      final stranger = ChannelSeal(other, topic, clock: clock);
      expect(await desktop.open('hello', await stranger.seal('hello', {'from': 'p1'})), isNull);
    });

    test("a phone's command replayed to the computer's next channel (the bridge restarted) is dropped", () async {
      final guard = ReplayGuard(clock: clock);
      final first = ChannelSeal(key, topic, guard: guard, clock: clock);
      final wire = await phone.seal('run', {'id': 'r1', 'op': 'send'});
      expect(await first.open('run', wire), isNotNull);
      now = now.add(const Duration(minutes: 1));
      final next = ChannelSeal(key, topic, guard: guard, clock: clock);
      expect(await next.open('run', wire), isNull);
      expect(await next.open('run', await phone.seal('run', {'id': 'r2'})), {'id': 'r2'});
    });

    test('a message sealed before the app started is dropped, a fresh one after it goes through', () async {
      final wire = await phone.seal('run', {'id': 'r1', 'op': 'send'});
      now = now.add(const Duration(seconds: 30));
      final restarted = ChannelSeal(key, topic, clock: clock);
      expect(await restarted.open('run', wire), isNull);
      expect(await restarted.open('run', await phone.seal('run', {'id': 'r2'})), {'id': 'r2'});
    });

    test("the phone drops the computer's messages replayed or out of order", () async {
      final first = await desktop.seal('screen', {'n': 1});
      final second = await desktop.seal('screen', {'n': 2});
      final third = await desktop.seal('ran', {'id': 'r1'});
      expect(await phone.open('screen', second), {'n': 2});
      expect(await phone.open('screen', first), isNull, reason: 'older than one already taken');
      expect(await phone.open('screen', second), isNull, reason: 'replayed');
      expect(await phone.open('ran', third), {'id': 'r1'});
      expect(await phone.open('ran', third), isNull);
    });

    test('a sender that starts again (new epoch) goes through; its old messages still do not', () async {
      final guard = ReplayGuard(clock: clock);
      final computer = ChannelSeal(key, topic, guard: guard, clock: clock);
      final old = await phone.seal('run', {'id': 'r1'});
      expect(await computer.open('run', old), isNotNull);
      final relaunched = ChannelSeal(key, topic, clock: clock);
      expect(await computer.open('hello', await relaunched.seal('hello', {'from': 'p1'})), {'from': 'p1'});
      expect(await computer.open('run', await relaunched.seal('run', {'id': 'r2'})), {'id': 'r2'});
      expect(await computer.open('run', old), isNull);
      expect(await computer.open('run', await phone.seal('run', {'id': 'r3'})), {'id': 'r3'});
    });

    test('a message without its epoch and count is dropped', () async {
      final env = await sealEnvelope(key, {
        'id': 'r1',
        'ts': now.millisecondsSinceEpoch,
        'mid': newMessageId(),
      }, channelAad(topic, 'run'));
      expect(await desktop.open('run', env), isNull);
    });

    test('epochs past the limit are forgotten oldest first; the newest still refuse a replay', () async {
      final guard = ReplayGuard(clock: clock, maxEpochs: 2);
      Map<String, dynamic> msg(String ep, int seq) => {
        'ts': now.millisecondsSinceEpoch,
        'mid': newMessageId(),
        'ep': ep,
        'seq': seq,
      };
      for (final ep in ['a', 'b', 'c']) {
        expect(guard.check(msg(ep, 5)), isNull);
      }
      expect(guard.check(msg('c', 5)), 'order');
      expect(guard.check(msg('b', 4)), 'order');
      expect(guard.check(msg('a', 1)), isNull, reason: 'forgotten');
    });
  });

  test("a sealed push opens for that computer's phones, with a time and an id inside", () async {
    final before = DateTime.now().millisecondsSinceEpoch;
    final a = await sealNotice(key, topic, {'title': 'Claude', 'body': 'Needs approval'});
    final b = await sealNotice(key, topic, {'title': 'Claude', 'body': 'Needs approval'});
    final opened = jsonDecode(utf8.decode((await openBytes(key, base64Decode(a), pushAad(topic)))!)) as Map;
    final again = jsonDecode(utf8.decode((await openBytes(key, base64Decode(b), pushAad(topic)))!)) as Map;
    expect(opened['title'], 'Claude');
    expect(opened['ts'] as int, greaterThanOrEqualTo(before));
    expect(opened['id'], isNot(again['id']));
    expect(await openBytes(key, base64Decode(a), pushAad('zzzz9999')), isNull);
    final activity = await sealActivity(key, topic, {'session': 's1', 'state': 'working'});
    expect(await openBytes(key, base64Decode(activity), pushAad(topic)), isNull);
    expect(await openBytes(key, base64Decode(activity), activityAad(topic)), isNotNull);
  });

  test('a key reads back from both of its spellings; anything else is no key', () {
    expect(ChannelKey.tryParse(key.toBase64()), key);
    expect(ChannelKey.tryParse(key.toBase64Url()), key);
    expect(key.toBase64Url(), isNot(contains('=')));
    expect(ChannelKey.tryParse(base64Encode(List.filled(16, 1))), isNull);
    expect(ChannelKey.tryParse('not a key'), isNull);
    expect(ChannelKey.tryParse(null), isNull);
    expect(ChannelKey.generate(), isNot(ChannelKey.generate()));
  });
}
