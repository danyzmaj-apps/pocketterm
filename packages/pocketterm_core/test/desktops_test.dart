import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/desktops.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final client = SupabaseClient('http://localhost:1', 'anon');

  Map<String, dynamic> row(String id, Duration ago, {String platform = 'macos'}) => {
    'id': id,
    'name': 'Computer $id',
    'platform': platform,
    'seen_at': DateTime.now().subtract(ago).toUtc().toIso8601String(),
  };

  test('the computer last shown stays shown while it is listed, even when another was seen since', () {
    final changes = <String?>[];
    final d = Desktops(client, saved: 'bbbbbbbb', onChanged: (_, id) => changes.add(id))
      ..apply([row('aaaaaaaa', Duration.zero), row('bbbbbbbb', const Duration(hours: 2))]);
    expect(d.selected?.id, 'bbbbbbbb');
    expect(changes, ['bbbbbbbb']);
  });

  test('with the last one gone, the newest seen is shown and kept as the computers take turns', () {
    final d = Desktops(client, saved: 'gone0000')
      ..apply([row('aaaaaaaa', Duration.zero), row('bbbbbbbb', const Duration(minutes: 1))]);
    expect(d.selected?.id, 'aaaaaaaa');
    d.apply([row('bbbbbbbb', Duration.zero), row('aaaaaaaa', const Duration(minutes: 1))]);
    expect(d.selected?.id, 'aaaaaaaa');
  });

  test('none listed, none shown; a computer not seen for 30 days is not listed', () {
    final d = Desktops(client)..apply([]);
    expect(d.selected, isNull);
    d.apply([row('aaaaaaaa', const Duration(days: 31))]);
    expect(d.all, isEmpty);
    expect(d.selected, isNull);
  });

  test('the person picks a listed computer only', () {
    final changes = <String?>[];
    final d = Desktops(client, onChanged: (_, id) => changes.add(id))
      ..apply([row('aaaaaaaa', Duration.zero), row('bbbbbbbb', Duration.zero, platform: 'windows')])
      ..select('bbbbbbbb')
      ..select('cccccccc');
    expect(d.selected?.id, 'bbbbbbbb');
    expect(d.selected?.windows, isTrue);
    expect(changes, ['aaaaaaaa', 'bbbbbbbb']);
  });

  test('the cached list shows the computer last shown before the server answers', () {
    final cached = Desktop.fromJson(row('bbbbbbbb', const Duration(minutes: 5)));
    final d = Desktops(client, cached: [cached], saved: 'bbbbbbbb');
    expect(d.loaded, isFalse);
    expect(d.selected, cached);
    expect(Desktop.fromJson(cached.toJson()), cached);
  });

  test('online means seen within two and a half minutes', () {
    expect(Desktop.fromJson(row('aaaaaaaa', const Duration(seconds: 140))).online, isTrue);
    expect(Desktop.fromJson(row('aaaaaaaa', const Duration(seconds: 160))).online, isFalse);
  });
}
