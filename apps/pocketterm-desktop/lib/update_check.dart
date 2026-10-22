import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// A PocketTerm release newer than this one: its [version] (`0.6.0`) and
/// its release page, where the installer is.
@immutable
class UpdateInfo {
  const UpdateInfo(this.version, this.url);

  final String version;
  final Uri url;

  @override
  bool operator ==(Object other) => other is UpdateInfo && other.version == version && other.url == url;

  @override
  int get hashCode => Object.hash(version, url);
}

/// Windows' update check (the Mac has Sparkle): asks GitHub for the latest
/// release on [start] and every [every] after. [update] is that release
/// while it's newer than this build; a check that fails shows nothing.
class UpdateCheck extends ChangeNotifier {
  UpdateCheck({http.Client? client, Future<String> Function()? version, this.every = const Duration(hours: 24)})
    : _client = client ?? http.Client(),
      _version = version ?? _installed;

  final http.Client _client;

  /// This build's version, without its build number.
  final Future<String> Function() _version;

  final Duration every;

  Timer? _timer;
  UpdateInfo? _update;

  static final Uri latest = Uri.parse('https://api.github.com/repos/danyzmaj-apps/pocketterm/releases/latest');

  UpdateInfo? get update => _update;

  static Future<String> _installed() async => (await PackageInfo.fromPlatform()).version;

  void start() {
    unawaited(check());
    _timer ??= Timer.periodic(every, (_) => unawaited(check()));
  }

  Future<void> check() async {
    UpdateInfo? found;
    try {
      final r = await _client
          .get(latest, headers: const {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 30));
      if (r.statusCode == 200) found = newer(jsonDecode(r.body), await _version());
    } on Object catch (e) {
      debugPrint('PocketTerm: update check: $e');
    }
    if (found == _update) return;
    _update = found;
    notifyListeners();
  }

  /// [release] (GitHub's JSON for one) if its tag, without a leading `v`, is
  /// a higher semantic version than [current], it has an https page and its
  /// Windows installer (`PocketTerm-<version>-setup.exe`) is on it: the Mac
  /// publishes a release before the Windows build attaches its installer,
  /// and an update offered then would lead to a page with nothing to run.
  @visibleForTesting
  static UpdateInfo? newer(Object? release, String current) {
    if (release case {'tag_name': final String tag, 'html_url': final String url}) {
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      final page = Uri.tryParse(url);
      final installer = switch (release['assets']) {
        final List<Object?> assets => assets.any(
          (a) => a is Map && a['name'] is String && (a['name'] as String).toLowerCase().endsWith('-setup.exe'),
        ),
        _ => false,
      };
      if ((compareVersions(version, current) ?? 0) > 0 && page != null && page.isScheme('https') && installer) {
        return UpdateInfo(version, page);
      }
    }
    return null;
  }

  static final _semver = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$');

  /// Semantic version order of [a] and [b] (negative, zero, positive), the
  /// build metadata (`+5`) ignored; null if either isn't one.
  @visibleForTesting
  static int? compareVersions(String a, String b) {
    final x = _semver.firstMatch(a);
    final y = _semver.firstMatch(b);
    if (x == null || y == null) return null;
    for (var i = 1; i <= 3; i++) {
      final c = int.parse(x[i]!).compareTo(int.parse(y[i]!));
      if (c != 0) return c;
    }
    // A pre-release (1.0.0-beta) comes before its release (1.0.0).
    final (p, q) = (x[4], y[4]);
    if (p == null || q == null) return p == q ? 0 : (p == null ? 1 : -1);
    final ps = p.split('.');
    final qs = q.split('.');
    for (var i = 0; i < min(ps.length, qs.length); i++) {
      final m = int.tryParse(ps[i]);
      final n = int.tryParse(qs[i]);
      final c = switch ((m, n)) {
        (final int m, final int n) => m.compareTo(n),
        (int(), null) => -1,
        (null, int()) => 1,
        _ => ps[i].compareTo(qs[i]),
      };
      if (c != 0) return c;
    }
    return ps.length.compareTo(qs.length);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client.close();
    super.dispose();
  }
}
