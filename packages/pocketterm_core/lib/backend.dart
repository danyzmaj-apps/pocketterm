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

  /// Asks the server for its health: reachable, a PocketTerm server, one
  /// this app speaks to. Null when all is well, else what's wrong.
  Future<String?> check() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse('$url/v1/health'));
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await utf8.decodeStream(res);
      if (res.statusCode == 404) return 'No PocketTerm server answers at this URL.';
      if (res.statusCode != 200) return 'The server answered with an error (${res.statusCode}).';
      final health = jsonDecode(body);
      final version = health is Map ? health['pocketterm'] : null;
      if (version is! int) return 'No PocketTerm server answers at this URL.';
      if (version > protocol) return 'Your server is newer than this app. Update PocketTerm, then retry.';
      return null;
    } on HandshakeException {
      return "Couldn't make a secure connection to $host.";
    } on IOException {
      // Refused, reset, or closed mid-answer (HttpException), e.g. a captive portal or a proxy.
      return onTailnet ? unreachable : "Couldn't reach $host. Check the URL and your connection.";
    } on TimeoutException {
      return '$host took too long to answer.';
    } on FormatException {
      return 'No PocketTerm server answers at this URL.';
    } finally {
      client.close(force: true);
    }
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
