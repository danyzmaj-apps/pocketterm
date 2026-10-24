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
  PairingCode({required this.hash, required this.expires, this.by});

  factory PairingCode.fromJson(Map<String, dynamic> j) =>
      PairingCode(hash: j['hash'] as String, expires: DateTime.parse(j['expires'] as String), by: j['by'] as String?);

  final String hash;
  final DateTime expires;

  /// The desktop device that asked for it (null in a state file from before it was kept); a code goes when that
  /// device signs out or is revoked.
  final String? by;

  Map<String, dynamic> toJson() => {'hash': hash, 'expires': iso(expires), 'by': ?by};
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
  ActivityToken({
    required this.token,
    required this.session,
    required this.platform,
    required this.device,
    this.ref,
    this.live,
  });

  factory ActivityToken.fromJson(Map<String, dynamic> j) => ActivityToken(
    token: j['token'] as String,
    session: j['session'] as String,
    platform: j['platform'] as String,
    device: j['device'] as String,
    ref: j['ref'] as String?,
    live: j['live'] as Map<String, dynamic>?,
  );

  /// How long after an iPhone's last push its state goes out again when its computer checks in: under the 3
  /// minutes after which the phone shows it stale, with room for a check-in a little early (every 60 seconds).
  static const refreshAfter = Duration(seconds: 110);

  final String token;
  final String session;
  final String platform;
  final String device;

  /// What an Android phone's pushes name [session] by: its tag under the computer's key (pocketterm_core's
  /// sessionTag), which the phone registered. An iPhone's activity has none: its token is its own.
  final String? ref;

  /// An iPhone's last state as it was pushed (`{state, since, kind?}`, never `ended`), sent again after
  /// [refreshAfter] while its computer checks in; Android's states are sealed and never kept.
  Map<String, dynamic>? live;

  /// When [live] last went out; null before it has (or since the server started), so it goes at the next check-in.
  DateTime? pushed;

  /// The computer whose session it follows: [session] is `<desktop id>/<key>`.
  String get desktop => session.split('/').first;

  Map<String, dynamic> toJson() => {
    'token': token,
    'session': session,
    'platform': platform,
    'device': device,
    'ref': ?ref,
    'live': ?live,
  };
}

String iso(DateTime t) => t.toUtc().toIso8601String();

/// The data directory couldn't be written (a full disk, a read-only or not-owned folder): what was being saved
/// wasn't. [message] names the file and the system's reason.
class StorageException implements Exception {
  StorageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Everything the server keeps but blobs: one JSON file (state.json) in the data directory, rewritten
/// atomically after every change: written whole to state.json.tmp and flushed, the previous state.json renamed to
/// state.json.bak, then the new one renamed into place. The setup token sits in its own file (setup-token) so
/// `pocketterm-server setup-link --new` can replace it while the server runs. One server at a time holds the
/// directory (a lock on its `.lock` file).
class Store {
  Store._(this.dir, this.serverId, this._lock);

  /// The store in [dir], made (with a new server id) when there is none. A state.json that can't be read is
  /// never replaced by an empty one: the previous one (state.json.bak) takes its place when it reads, the bad
  /// one kept beside it as state.json.corrupt-<time>; otherwise this throws and leaves both as they are.
  /// Throws [StorageException] when [dir] can't be written or another server holds it.
  factory Store.open(Directory dir, {void Function(String message)? log}) {
    final RandomAccessFile lock;
    try {
      dir.createSync(recursive: true);
      lock = File('${dir.path}/.lock').openSync(mode: FileMode.append);
    } on FileSystemException catch (e) {
      throw StorageException(
        "Can't write to the data folder ${dir.absolute.path} (${e.osError?.message ?? e.message}). The server "
        'needs to own it; in Docker it runs as user 65532: `chown -R 65532:65532 <folder>` for a folder you mount.',
      );
    }
    try {
      lock.lockSync();
    } on FileSystemException {
      lock.closeSync();
      throw StorageException('Another PocketTerm server is using ${dir.absolute.path}. Stop it first.');
    }
    try {
      return _load(dir, lock, log)..save();
    } on Object {
      lock.closeSync();
      rethrow;
    }
  }

  static Store _load(Directory dir, RandomAccessFile lock, void Function(String)? log) {
    final file = File('${dir.path}/$_stateFile');
    final backup = File('${dir.path}/$_stateFile.bak');
    final pending = File('${dir.path}/$_stateFile.tmp');
    if (!file.existsSync()) {
      // A save stopped between its two renames: the new state is whole in .tmp, the one before in .bak.
      for (final f in [pending, backup]) {
        if (!f.existsSync()) continue;
        try {
          final store = _read(f, dir, lock);
          log?.call('${file.path} was missing: started from ${f.path}.');
          return store;
        } on Object catch (e) {
          log?.call("${f.path} doesn't read either: $e");
        }
      }
      if (backup.existsSync()) {
        throw StorageException(
          "${file.path} is missing and ${backup.path} doesn't read. Restore the data folder from a backup, or "
          'remove ${backup.path} to start over (every device then signs in again).',
        );
      }
      return Store._(dir, newId(), lock);
    }
    try {
      return _read(file, dir, lock);
    } on Object catch (e) {
      final Store store;
      try {
        store = _read(backup, dir, lock);
      } on Object {
        throw StorageException(
          "${file.path} doesn't read ($e) and there is no usable ${backup.path}. It is left as it is: restore it "
          'from a backup, or move it away to start over (every device then signs in again).',
        );
      }
      final kept = '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
      file.renameSync(kept);
      log?.call(
        "${file.path} doesn't read ($e): kept it as $kept and started from ${backup.path}, the state before the "
        'last change. A device signed in by that change signs in again.',
      );
      return store;
    }
  }

  /// The store saved in [file]; throws when it isn't one (bad JSON, a missing or mistyped field).
  static Store _read(File file, Directory dir, RandomAccessFile lock) {
    final j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final store = Store._(dir, j['server_id'] as String, lock);
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
  final RandomAccessFile _lock;

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

  /// Writes state.json; throws [StorageException] when it can't (what's in memory stays, saved by the next
  /// save that works).
  void save() {
    final file = File('${dir.path}/$_stateFile');
    _writeAtomically(file, const JsonEncoder.withIndent(' ').convert(_toJson()), backup: true);
  }

  /// Makes [apply]'s change and saves it. When the save fails, the change is undone (so a 507 means nothing
  /// changed) and the [StorageException] thrown.
  void change(void Function() apply) {
    final devices = {...this.devices};
    final desktops = {...this.desktops};
    final pairingCodes = {...this.pairingCodes};
    final pushTokens = {...this.pushTokens};
    final activityTokens = [...this.activityTokens];
    apply();
    try {
      save();
    } on StorageException {
      this.devices
        ..clear()
        ..addAll(devices);
      this.desktops
        ..clear()
        ..addAll(desktops);
      this.pairingCodes
        ..clear()
        ..addAll(pairingCodes);
      this.pushTokens
        ..clear()
        ..addAll(pushTokens);
      this.activityTokens
        ..clear()
        ..addAll(activityTokens);
      rethrow;
    }
  }

  /// Lets another server open [dir].
  void close() => _lock.closeSync();

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

  /// [content] into [file] whole or not at all; with [backup], the file it replaces becomes `<file>.bak`.
  static void _writeAtomically(File file, String content, {bool backup = false}) {
    final tmp = File('${file.path}.tmp');
    try {
      final raf = tmp.openSync(mode: FileMode.write);
      try {
        raf
          ..writeStringSync(content)
          ..flushSync();
      } finally {
        raf.closeSync();
      }
      if (backup && file.existsSync()) file.renameSync('${file.path}.bak');
      tmp.renameSync(file.path);
    } on FileSystemException catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } on FileSystemException {
        // Gone with the rest of the folder.
      }
      throw StorageException("Couldn't save ${file.path}: ${e.osError?.message ?? e.message}.");
    }
  }
}
