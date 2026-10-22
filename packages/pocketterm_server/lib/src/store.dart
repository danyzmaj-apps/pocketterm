import 'dart:convert';
import 'dart:io';

import 'package:pocketterm_server/src/secrets.dart';

/// A signed-in computer (role desktop) or phone (role phone).
class Device {
  Device({
    required this.id,
    required this.role,
    required this.label,
    required this.platform,
    required this.tokenHash,
    required this.created,
    required this.seen,
  });

  factory Device.fromJson(Map<String, dynamic> j) => Device(
    id: j['id'] as String,
    role: j['role'] as String,
    label: j['label'] as String,
    platform: j['platform'] as String,
    tokenHash: j['token_hash'] as String,
    created: DateTime.parse(j['created_at'] as String),
    seen: DateTime.parse(j['seen_at'] as String),
  );

  final String id;
  final String role;
  final String label;
  final String platform;
  final String tokenHash;
  final DateTime created;
  DateTime seen;

  bool get isDesktop => role == 'desktop';

  /// What clients see: everything but the token's hash.
  Map<String, dynamic> toApi() => {
    'id': id,
    'role': role,
    'label': label,
    'platform': platform,
    'created_at': iso(created),
    'seen_at': iso(seen),
  };

  Map<String, dynamic> toJson() => {...toApi(), 'token_hash': tokenHash};
}

/// A computer as phones list it.
class Desktop {
  Desktop({required this.id, required this.name, required this.platform, required this.seen, this.device});

  factory Desktop.fromJson(Map<String, dynamic> j) => Desktop(
    id: j['id'] as String,
    name: j['name'] as String,
    platform: j['platform'] as String,
    seen: DateTime.parse(j['seen_at'] as String),
    device: j['device'] as String?,
  );

  final String id;
  final String name;
  final String platform;
  final DateTime seen;

  /// The desktop device that last checked it in (null in a state file from before it was kept).
  final String? device;

  Map<String, dynamic> get _row => {'id': id, 'name': name, 'platform': platform, 'seen_at': iso(seen)};

  Map<String, dynamic> toJson() => {..._row, 'device': ?device};

  /// What clients see: online when it checked in within [onlineFor] of [now] (the server's clock, so a phone's
  /// wrong clock doesn't matter).
  Map<String, dynamic> toApi(DateTime now) => {..._row, 'online': now.difference(seen) < onlineFor};

  /// A computer stamps its row every 60 seconds; two missed stamps and a margin mean it's offline.
  static const onlineFor = Duration(seconds: 150);

  /// After this long without a check-in, the server ends the Live Activities of its sessions.
  static const activitiesFor = Duration(minutes: 3);
}

/// A single-use pairing code, by its SHA-256.
class PairingCode {
  PairingCode({required this.hash, required this.expires, required this.by});

  factory PairingCode.fromJson(Map<String, dynamic> j) =>
      PairingCode(hash: j['hash'] as String, expires: DateTime.parse(j['expires'] as String), by: j['by'] as String);

  final String hash;
  final DateTime expires;

  /// The desktop device that asked for it.
  final String by;

  Map<String, dynamic> toJson() => {'hash': hash, 'expires': iso(expires), 'by': by};
}

/// A phone's push token (APNs or FCM), registered by device [device].
class PushToken {
  PushToken({required this.token, required this.platform, required this.label, required this.device});

  factory PushToken.fromJson(Map<String, dynamic> j) => PushToken(
    token: j['token'] as String,
    platform: j['platform'] as String,
    label: j['label'] as String,
    device: j['device'] as String,
  );

  final String token;
  final String platform;
  final String label;
  final String device;

  Map<String, dynamic> toJson() => {'token': token, 'platform': platform, 'label': label, 'device': device};
}

/// A Live Activity's push token following coding [session].
class ActivityToken {
  ActivityToken({required this.token, required this.session, required this.platform, required this.device});

  factory ActivityToken.fromJson(Map<String, dynamic> j) => ActivityToken(
    token: j['token'] as String,
    session: j['session'] as String,
    platform: j['platform'] as String,
    device: j['device'] as String,
  );

  final String token;
  final String session;
  final String platform;
  final String device;

  /// The computer whose session it follows: [session] is `<desktop id>/<key>`.
  String get desktop => session.split('/').first;

  Map<String, dynamic> toJson() => {'token': token, 'session': session, 'platform': platform, 'device': device};
}

String iso(DateTime t) => t.toUtc().toIso8601String();

/// Everything the server keeps but blobs: one JSON file (state.json) in the data directory, rewritten
/// atomically (a temporary file, flushed, then renamed over it) after every change. The setup token sits in
/// its own file (setup-token) so `pocketterm-server setup-link --new` can replace it while the server runs.
class Store {
  Store._(this.dir, this.serverId);

  /// The store in [dir], made (with a new server id) when there is none. A state file that can't be read
  /// throws rather than being replaced: it holds every device's sign-in.
  factory Store.open(Directory dir) {
    dir.createSync(recursive: true);
    final file = File('${dir.path}/$_stateFile');
    if (!file.existsSync()) {
      final store = Store._(dir, newId())..save();
      return store;
    }
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } on FormatException catch (e) {
      throw StateError('${file.path} is not valid JSON ($e). Restore it from a backup or move it away.');
    }
    final store = Store._(dir, j['server_id'] as String);
    List<Map<String, dynamic>> rows(String key) => [
      for (final r in (j[key] as List<dynamic>? ?? const [])) r as Map<String, dynamic>,
    ];
    for (final r in rows('devices')) {
      final d = Device.fromJson(r);
      store.devices[d.id] = d;
    }
    for (final r in rows('desktops')) {
      final d = Desktop.fromJson(r);
      store.desktops[d.id] = d;
    }
    for (final r in rows('pairing_codes')) {
      final c = PairingCode.fromJson(r);
      store.pairingCodes[c.hash] = c;
    }
    for (final r in rows('push_tokens')) {
      final t = PushToken.fromJson(r);
      store.pushTokens[t.token] = t;
    }
    store.activityTokens.addAll(rows('activity_tokens').map(ActivityToken.fromJson));
    return store;
  }

  static const _stateFile = 'state.json';
  static const _setupFile = 'setup-token';

  final Directory dir;

  /// Made once with the data directory; clients key per-server state on it.
  final String serverId;

  final Map<String, Device> devices = {};
  final Map<String, Desktop> desktops = {};
  final Map<String, PairingCode> pairingCodes = {};
  final Map<String, PushToken> pushTokens = {};
  final List<ActivityToken> activityTokens = [];

  Device? deviceByTokenHash(String hash) {
    for (final d in devices.values) {
      if (d.tokenHash == hash) return d;
    }
    return null;
  }

  void save() {
    _writeAtomically(File('${dir.path}/$_stateFile'), const JsonEncoder.withIndent(' ').convert(_toJson()));
  }

  Map<String, dynamic> _toJson() => {
    'version': 1,
    'server_id': serverId,
    'devices': [for (final d in devices.values) d.toJson()],
    'desktops': [for (final d in desktops.values) d.toJson()],
    'pairing_codes': [for (final c in pairingCodes.values) c.toJson()],
    'push_tokens': [for (final t in pushTokens.values) t.toJson()],
    'activity_tokens': [for (final t in activityTokens) t.toJson()],
  };

  /// Whether [dir] has a setup token yet (it hasn't before the server first starts there).
  static bool hasSetupToken(Directory dir) => File('${dir.path}/$_setupFile').existsSync();

  /// The setup token in [dir], made when there is none.
  static String setupToken(Directory dir) {
    final file = File('${dir.path}/$_setupFile');
    if (file.existsSync()) {
      final token = file.readAsStringSync().trim();
      if (token.isNotEmpty) return token;
    }
    return replaceSetupToken(dir);
  }

  /// Replaces the setup token in [dir] with a new one and returns it.
  static String replaceSetupToken(Directory dir) {
    dir.createSync(recursive: true);
    final token = newToken();
    _writeAtomically(File('${dir.path}/$_setupFile'), '$token\n');
    return token;
  }

  static void _writeAtomically(File file, String content) {
    final tmp = File('${file.path}.tmp');
    final raf = tmp.openSync(mode: FileMode.write);
    try {
      raf
        ..writeStringSync(content)
        ..flushSync();
    } finally {
      raf.closeSync();
    }
    tmp.renameSync(file.path);
  }
}
