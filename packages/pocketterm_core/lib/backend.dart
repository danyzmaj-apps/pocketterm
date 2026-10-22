import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The PocketTerm server this device connects through
/// (packages/pocketterm_server/PROTOCOL.md): one on a VPS, or the one built
/// into a computer's app, reached on the same network or through Tailscale.
/// A computer signs in with the server's setup link
/// (`pocketterm://setup?url=…&setup=…`, printed by the server); a phone
/// with a computer's code, a setup link with a pairing code and that
/// computer's key in it (`pocketterm://setup?url=…&code=…&d=…&k=…`). A
/// computer keeps it in its shared preferences; a phone where its native
/// side reads it too: the App Group on iOS
/// (apps/pocketterm-mobile/ios/Shared/PocketTermShared.swift), shared
/// preferences on Android (PocketTermShared.kt).
@immutable
class Backend {
  const Backend({required this.url});

  /// The server's public URL, `https://pocketterm.example.com` or
  /// `https://my-mac.tail1234.ts.net`, without a trailing slash.
  final String url;

  /// [url] as typed, or a reason it can't be used.
  static ({Backend? backend, String? error}) parse(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    // The API's own path works too.
    u = u.replaceFirst(RegExp(r'/v1$'), '');
    final uri = Uri.tryParse(u);
    if (u.isEmpty || uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return (backend: null, error: 'Enter your server URL, like https://pocketterm.example.com.');
    }
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && _isThisMachine(uri.host))) {
      return (backend: null, error: 'The server URL must start with https://.');
    }
    if (uri.path.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return (backend: null, error: 'Use the server URL alone, without a path.');
    }
    return (backend: Backend(url: u), error: null);
  }

  /// A `pocketterm://setup?url=…` link (its pairing code, if any, is
  /// [pairingCode]'s; its setup token [setupToken]'s). A link from
  /// PocketTerm 0.1 ([isOldLink]) isn't one: its URL is a Supabase project.
  static Backend? fromLink(Uri uri) {
    if (uri.scheme != 'pocketterm' || uri.host != 'setup' || isOldLink(uri)) return null;
    final url = uri.queryParameters['url'];
    return url == null ? null : parse(url).backend;
  }

  /// A setup link from PocketTerm 0.1, which worked through a Supabase
  /// project: it carries that project's `key`.
  static bool isOldLink(Uri uri) =>
      uri.scheme == 'pocketterm' && uri.host == 'setup' && uri.queryParameters.containsKey('key');

  /// The pairing code in a setup link (the computer's QR), if it has one:
  /// it signs a phone in.
  static String? pairingCode(Uri uri) => _param(uri, 'code');

  /// The setup token in a server's setup link, if it has one: it signs a
  /// computer in.
  static String? setupToken(Uri uri) => _param(uri, 'setup');

  static String? _param(Uri uri, String name) {
    if (fromLink(uri) == null) return null;
    final value = uri.queryParameters[name]?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  /// The computer and its channel key in a setup link (`d`, `k`: the
  /// computer's QR), if it has them. A link without them still signs in;
  /// that computer then stays locked on the phone.
  static ComputerKey? computerKey(Uri uri) {
    if (fromLink(uri) == null) return null;
    final desktop = uri.queryParameters['d'] ?? '';
    final key = ChannelKey.tryParse(uri.queryParameters['k']);
    if (key == null || !RegExp(r'^[a-z0-9]{8}$').hasMatch(desktop)) return null;
    return (desktop: desktop, key: key);
  }

  Uri get link => Uri(scheme: 'pocketterm', host: 'setup', queryParameters: {'url': url});

  /// [link] with a pairing code and, from a computer, its [computer] key:
  /// what the computer's QR holds. A secret: whoever has it reads that
  /// computer's sessions.
  Uri linkWithCode(String code, {ComputerKey? computer}) => Uri(
    scheme: 'pocketterm',
    host: 'setup',
    queryParameters: {
      'url': url,
      'code': code,
      if (computer != null) ...{'d': computer.desktop, 'k': computer.key.toBase64Url()},
    },
  );

  /// The host, for display.
  String get host => Uri.parse(url).host;

  /// Reached through Tailscale (`tailscale serve` on a computer): only a
  /// device on that tailnet, with Tailscale on, can reach it.
  bool get onTailnet => host.endsWith('.ts.net');

  /// Why this device gets no answer from the server, worded for the person:
  /// a Tailscale address needs Tailscale on here.
  String get unreachable => onTailnet
      ? "Can't reach $host. It's on your tailnet: open Tailscale on this device and connect."
      : "Can't reach $host. Check your connection.";

  /// Plain http only to this machine (a computer reaching the server built
  /// into it); everything else, Tailscale included (`tailscale serve` gives
  /// it a ts.net certificate), needs https.
  static bool _isThisMachine(String host) =>
      host == 'localhost' || host == '::1' || host == '[::1]' || RegExp(r'^127\.').hasMatch(host);

  /// The protocol version this app speaks (GET /v1/health).
  static const protocol = 1;

  /// The oldest PocketTerm server this app works with (GET /v1/health's
  /// `version`).
  static const minServer = '0.1.0';

  /// How far this device's clock may be off the server's before
  /// [clockWarning] speaks up: each side drops sealed messages more than 5
  /// minutes off its own clock, so two devices each within 2 minutes stay
  /// within reach of each other.
  static const clockTolerance = Duration(minutes: 2);

  /// Asks the server for its health: reachable, a PocketTerm server, one
  /// this app speaks to. Null when all is well, else what's wrong.
  Future<String?> check() async => (await health()).error;

  /// GET /v1/health: `error` is null when all is well, else what's wrong,
  /// worded for the person. `clockOffset` is how far the server's clock is
  /// ahead of this device's (null when it didn't say); see [clockWarning].
  Future<({String? error, Duration? clockOffset})> health() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    ({String? error, Duration? clockOffset}) fail(String error) => (error: error, clockOffset: null);
    try {
      final sent = DateTime.now();
      final req = await client.getUrl(Uri.parse('$url/v1/health'));
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await utf8.decodeStream(res);
      final received = DateTime.now();
      final status = res.statusCode;
      if (status >= 520 && status <= 530 && (res.headers.value('cf-ray') != null || _cloudflare(res))) {
        return fail(
          "Cloudflare answers for $host but can't reach your server ($status). Turn the orange cloud off for "
          'this name (DNS only), or set SSL/TLS to Full (strict) in Cloudflare.',
        );
      }
      if (status == 502 || status == 503 || status == 504) {
        return fail(
          "$host answers, but the PocketTerm server behind it doesn't ($status). On a VPS, check that it runs: "
          '`docker compose ps` and `docker compose logs server`.',
        );
      }
      if (status == 404) return fail('No PocketTerm server answers at this URL.');
      if (status != 200) return fail('The server answered with an error ($status).');
      final health = jsonDecode(body);
      final version = health is Map ? health['pocketterm'] : null;
      if (version is! int) return fail('No PocketTerm server answers at this URL.');
      if (version > protocol) return fail('Your server is newer than this app. Update PocketTerm, then retry.');
      final serverVersion = (health as Map)['version'];
      if (serverVersion is String && _olderThan(serverVersion, minServer)) {
        return fail(
          'Your server runs PocketTerm server $serverVersion; this app needs $minServer or newer. Update the '
          'server (on a VPS: `docker compose pull && docker compose up -d`; built into PocketTerm on a computer: '
          'update PocketTerm there), then retry.',
        );
      }
      final time = DateTime.tryParse(health['time'] as String? ?? '');
      // The server read its clock about halfway through the round trip.
      final here = sent.add(received.difference(sent) ~/ 2);
      return (error: null, clockOffset: time?.difference(here));
    } on HandshakeException {
      return fail(
        "Couldn't make a secure connection to $host: its HTTPS certificate isn't valid or isn't there yet. A new "
        'server takes a minute to get one; on a VPS, `docker compose logs caddy` says what went wrong.',
      );
    } on RedirectException {
      return fail(
        '$host keeps redirecting to itself. If it is behind Cloudflare, set SSL/TLS to Full (strict) in '
        'Cloudflare.',
      );
    } on IOException {
      // Refused, reset, or closed mid-answer (HttpException), e.g. a captive portal or a proxy.
      return fail(onTailnet ? unreachable : "Couldn't reach $host. Check the URL and your connection.");
    } on TimeoutException {
      return fail('$host took too long to answer.');
    } on FormatException {
      return fail('No PocketTerm server answers at this URL.');
    } finally {
      client.close(force: true);
    }
  }

  /// What to tell the person when this device's clock is [offset] off the
  /// server's by more than [clockTolerance]; null when it's close enough or
  /// unknown.
  static String? clockWarning(Duration? offset) {
    if (offset == null || offset.abs() <= clockTolerance) return null;
    final minutes = (offset.inSeconds.abs() / 60).round();
    return "This device's clock is $minutes minutes ${offset.isNegative ? 'ahead of' : 'behind'} the server's, so "
        "its messages to your other devices are dropped. Turn on Set time automatically in this device's date and "
        'time settings.';
  }

  static bool _cloudflare(HttpClientResponse res) => res.headers.value('server')?.toLowerCase() == 'cloudflare';

  /// Whether version [a] (`1.2.3`) comes before [b].
  static bool _olderThan(String a, String b) {
    List<int> parts(String v) => [for (final p in v.split('-').first.split('.')) int.tryParse(p) ?? 0];
    final x = parts(a);
    final y = parts(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d < 0;
    }
    return false;
  }

  /// The server this device was connected to, if any. One saved by an app
  /// from before (a Supabase project, which came with a key) isn't one.
  static Future<Backend?> load({bool? desktop}) async {
    if (_inPrefs(desktop)) {
      final prefs = await SharedPreferences.getInstance();
      final url = prefs.getString(_urlKey);
      return url == null || prefs.containsKey(_oldKeyKey) ? null : parse(url).backend;
    }
    final saved = await Native.getBackend();
    if (saved == null || saved.legacy) return null;
    return parse(saved.url).backend;
  }

  Future<void> save({bool? desktop}) async {
    if (!_inPrefs(desktop)) return await Native.setBackend(url: url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, url);
    await prefs.remove(_oldKeyKey);
  }

  static Future<void> clear({bool? desktop}) async {
    if (!_inPrefs(desktop)) return await Native.setBackend();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_urlKey);
    await prefs.remove(_oldKeyKey);
  }

  /// A computer ([desktop], macOS and Windows unless told) keeps it in its
  /// shared preferences under these keys; a phone where its native side
  /// reads it too.
  static bool _inPrefs(bool? desktop) => desktop ?? (Platform.isMacOS || Platform.isWindows);
  static const _urlKey = 'backend_url';

  /// Where an app from before kept its Supabase project's key.
  static const _oldKeyKey = 'backend_key';

  @override
  bool operator ==(Object other) => other is Backend && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
