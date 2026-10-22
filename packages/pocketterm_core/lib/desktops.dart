import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/timing.dart';

/// A computer running PocketTerm on this server (GET /v1/desktops): it
/// refreshes [seenAt] every minute while its terminal bridge runs, and the
/// phone talks to it on its own topic, its id.
@immutable
class Desktop {
  const Desktop({required this.id, required this.name, required this.platform, required this.seenAt});

  factory Desktop.fromJson(Map<String, dynamic> j) => Desktop(
    id: j['id'] as String,
    name: j['name'] as String,
    platform: j['platform'] as String,
    seenAt: DateTime.parse(j['seen_at'] as String),
  );

  /// 8 characters, a-z and 0-9.
  final String id;
  final String name;

  /// `macos` or `windows`.
  final String platform;
  final DateTime seenAt;

  bool get windows => platform == 'windows';

  /// It has said so within two and a half of its one-minute beats.
  bool get online => DateTime.now().difference(seenAt) < onlineWithin;

  /// How recently a computer has to have said it's there to count as
  /// [online].
  static const onlineWithin = Duration(seconds: 150);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
    'seen_at': seenAt.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is Desktop && other.id == id && other.name == name && other.platform == platform && other.seenAt == seenAt;

  @override
  int get hashCode => Object.hash(id, name, platform, seenAt);
}

/// Phone: the server's computers, newest seen first, and the one the
/// Terminal tab shows ([selected]).
class Desktops extends ChangeNotifier {
  /// [cached]: the list as last seen, [saved]: the computer last shown, both
  /// from before this launch (shown until the server says otherwise);
  /// [onChanged] keeps them for the next one.
  Desktops(this._server, {List<Desktop> cached = const [], String? saved, this.onChanged})
    : all = cached,
      _selectedId = saved;

  final Server _server;

  /// The list or the selection changed.
  final void Function(List<Desktop> all, String? selected)? onChanged;

  /// Computers seen this long ago or longer aren't listed.
  static const keepFor = Duration(days: 30);

  List<Desktop> all;

  /// The server has answered since launch.
  bool loaded = false;

  String? _selectedId;

  Desktop? get selected => all.where((d) => d.id == _selectedId).firstOrNull;

  /// Why the last [refresh] got no list (the server can't be reached, say);
  /// null once one came.
  String? error;

  /// Fetches the list; on failure the last one stays, and [error] says why.
  /// One that comes back after [dispose] (signed out meanwhile) is dropped:
  /// it would keep the old server's computers for the next sign-in.
  Future<void> refresh() async {
    try {
      final rows = await _server.desktops();
      timing('computers listed');
      if (!_disposed) apply(rows);
    } on Object catch (e) {
      timing('computers failed');
      debugPrint('PocketTerm: computers: $e');
      final why = e is ServerException ? e.message : '$e';
      if (_disposed || why == error) return;
      error = why;
      notifyListeners();
    }
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// The rows from the server, newest seen first.
  @visibleForTesting
  void apply(List<Map<String, dynamic>> rows) {
    final now = DateTime.now();
    all = [for (final r in rows) Desktop.fromJson(r)].where((d) => now.difference(d.seenAt) < keepFor).toList();
    loaded = true;
    error = null;
    _pick();
    onChanged?.call(all, _selectedId);
    notifyListeners();
  }

  /// The person shows [id]'s sessions.
  void select(String id) {
    if (id == _selectedId || !all.any((d) => d.id == id)) return;
    _selectedId = id;
    onChanged?.call(all, _selectedId);
    notifyListeners();
  }

  /// The person just scanned [id]'s code: it's shown now if listed, else as
  /// soon as [apply] lists it, whichever computer was seen last.
  void show(String id) {
    if (all.any((d) => d.id == id)) {
      _wanted = null;
      select(id);
    } else {
      _wanted = id;
    }
  }

  String? _wanted;

  /// The one asked for by [show] once listed; else the one shown stays while
  /// listed; else the newest seen (kept from then on, so it doesn't flip as
  /// computers take turns being newest); else none.
  void _pick() {
    if (_wanted case final w? when all.any((d) => d.id == w)) {
      _selectedId = w;
      _wanted = null;
    }
    if (selected == null) _selectedId = all.firstOrNull?.id;
  }
}
