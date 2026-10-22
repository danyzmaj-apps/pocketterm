import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Starts a program, as [Process.start] does; tests hand in a fake.
typedef StartProcess = Future<Process> Function(String executable, List<String> arguments);

/// Where Tailscale stands on this computer.
enum TailscaleState {
  /// No Tailscale CLI here: install Tailscale.
  missing,

  /// Installed, but not running or switched off: open Tailscale.
  stopped,

  /// Running, but signed out of its tailnet: open Tailscale and sign in.
  loggedOut,

  /// Connected to its tailnet.
  running,
}

/// What `tailscale status --json` says about this computer.
@immutable
class TailscaleStatus {
  const TailscaleStatus(this.state, {this.dnsName, this.https = false});

  final TailscaleState state;

  /// This computer's MagicDNS name without the trailing dot
  /// (`mac.tail1234.ts.net`); null without MagicDNS.
  final String? dnsName;

  /// HTTPS certificates are on for the tailnet (CertDomains isn't empty).
  final bool https;

  /// Where `tailscale serve` publishes this computer: `https://<dnsName>`.
  Uri? get url => dnsName == null ? null : Uri(scheme: 'https', host: dnsName);
}

/// How `tailscale serve` went.
@immutable
class ServeResult {
  const ServeResult.ok() : enableLink = null, error = null, taken = null;
  const ServeResult.needsHttps(Uri this.enableLink) : error = null, taken = null;
  const ServeResult.failed(String this.error) : enableLink = null, taken = null;

  /// Port 443 of this computer's Tailscale name already serves something
  /// else ([taken] says what), so nothing was changed.
  const ServeResult.taken(String this.taken)
    : enableLink = null,
      error =
          'Tailscale already serves $taken on this computer’s HTTPS port (443). PocketTerm leaves it alone: '
          'remove it with tailscale serve --https=443 off, or serve it on another port, then check again.';

  /// The tailnet has HTTPS (Serve) off: the page that turns it on.
  final Uri? enableLink;

  /// What the CLI said when it failed otherwise.
  final String? error;

  /// What already uses port 443 ([ServeResult.taken]).
  final String? taken;

  bool get ok => enableLink == null && error == null;
}

/// The Tailscale CLI: whether Tailscale runs here and under which name, and
/// `tailscale serve`, which publishes the built-in server at
/// `https://<this computer>.<tailnet>.ts.net` to the tailnet only.
class Tailscale {
  Tailscale({StartProcess? start, String? Function()? locate})
    : _start = start ?? _startCli,
      _locate = locate ?? findCli;

  /// The Mac app's binary is the CLI only when started from a terminal; started
  /// by an app (no TERM), it tries to open its window and prints nothing.
  /// `TAILSCALE_BE_CLI` tells it to act as the CLI either way.
  static Future<Process> _startCli(String executable, List<String> arguments) =>
      Process.start(executable, arguments, environment: cliEnvironment);

  @visibleForTesting
  static const cliEnvironment = {'TAILSCALE_BE_CLI': '1'};

  final StartProcess _start;
  final String? Function() _locate;

  /// Where to get Tailscale.
  static final Uri download = Uri.parse('https://tailscale.com/download');

  /// The admin console's DNS page: MagicDNS and HTTPS certificates.
  static final Uri adminDns = Uri.parse('https://login.tailscale.com/admin/dns');

  /// The Mac app's CLI (App Store and standalone builds alike).
  static const macCli = '/Applications/Tailscale.app/Contents/MacOS/Tailscale';

  /// Windows' CLI, and the app that shows Tailscale's window, in Program
  /// Files ([programFiles], which needn't be on C:).
  static String windowsCli([String? programFiles]) =>
      p.windows.join(programFiles ?? _programFiles, 'Tailscale', 'tailscale.exe');
  static String windowsApp([String? programFiles]) =>
      p.windows.join(programFiles ?? _programFiles, 'Tailscale', 'tailscale-ipn.exe');
  static String get _programFiles => Platform.environment['ProgramFiles'] ?? r'C:\Program Files';

  /// What `winget` installs on Windows.
  static const wingetInstall = [
    'winget',
    'install',
    '--id',
    'Tailscale.Tailscale',
    '--exact',
    '--source',
    'winget',
    '--accept-source-agreements',
    '--accept-package-agreements',
  ];

  /// Where to get Tailscale for Windows by hand.
  static final Uri windowsDownload = Uri.parse('https://tailscale.com/download/windows');

  /// The CLI: the app's own on a Mac or Windows, else `tailscale` on the
  /// PATH (a GUI app's PATH is short, so Homebrew's folders too: the open
  /// source build). Null when Tailscale isn't installed.
  static String? findCli({Map<String, String>? env, bool Function(String path)? exists, bool? windows}) {
    final isFile = exists ?? (String path) => File(path).existsSync();
    final win = windows ?? Platform.isWindows;
    final vars = env ?? Platform.environment;
    final app = win ? windowsCli(vars['ProgramFiles'] ?? r'C:\Program Files') : macCli;
    if (isFile(app)) return app;
    final dirs = [
      ...(vars['PATH'] ?? '').split(win ? ';' : ':').where((d) => d.isNotEmpty),
      if (!win) ...['/opt/homebrew/bin', '/usr/local/bin'],
    ];
    for (final dir in dirs) {
      final path = win ? p.windows.join(dir, 'tailscale.exe') : p.posix.join(dir, 'tailscale');
      if (isFile(path)) return path;
    }
    return null;
  }

  /// Whether Tailscale runs here, signed in, and this computer's name.
  Future<TailscaleStatus> status() async {
    final cli = _locate();
    if (cli == null) return const TailscaleStatus(TailscaleState.missing);
    final ({int? code, String out}) run;
    try {
      run = await _run(cli, ['status', '--json'], timeout: const Duration(seconds: 10));
    } on Object catch (e) {
      debugPrint('PocketTerm: tailscale status: $e');
      return const TailscaleStatus(TailscaleState.stopped);
    }
    return parseStatus(run.out);
  }

  /// `tailscale status --json`'s output read; anything else (the service
  /// isn't running) reads as stopped.
  @visibleForTesting
  static TailscaleStatus parseStatus(String out) {
    final Object? json;
    try {
      json = jsonDecode(out.substring(out.indexOf('{').clamp(0, out.length)));
    } on FormatException {
      return const TailscaleStatus(TailscaleState.stopped);
    }
    if (json is! Map) return const TailscaleStatus(TailscaleState.stopped);
    final state = switch (json['BackendState']) {
      'Running' => TailscaleState.running,
      'NeedsLogin' || 'NeedsMachineAuth' => TailscaleState.loggedOut,
      _ => TailscaleState.stopped,
    };
    if (state != TailscaleState.running) return TailscaleStatus(state);
    var name = (json['Self'] is Map ? (json['Self'] as Map)['DNSName'] : null) as String? ?? '';
    while (name.endsWith('.')) {
      name = name.substring(0, name.length - 1);
    }
    final certs = json['CertDomains'];
    return TailscaleStatus(state, dnsName: name.isEmpty ? null : name, https: certs is List && certs.isNotEmpty);
  }

  /// Publishes `http://127.0.0.1:<port>` at `https://<this computer's name>`
  /// on the tailnet, in the background (`tailscale serve --bg`), so it
  /// lasts until [unserve]. A tailnet with HTTPS off answers with the page
  /// that turns it on: the CLI prints it and waits, so it's stopped there.
  /// Something else already served on 443 ([servedElsewhere]) stays: it's
  /// never replaced.
  Future<ServeResult> serve(int port) async {
    final cli = _locate();
    if (cli == null) return const ServeResult.failed('Tailscale isn’t installed.');
    if (await taken(port) case final what?) return ServeResult.taken(what);
    final ({int? code, String out}) run;
    try {
      run = await _run(
        cli,
        ['serve', '--bg', '--https=443', 'http://127.0.0.1:$port'],
        timeout: const Duration(seconds: 30),
        stopWhen: (out) => enableLinkIn(out) != null,
      );
    } on Object catch (e) {
      return ServeResult.failed('$e');
    }
    if (enableLinkIn(run.out) case final link?) return ServeResult.needsHttps(link);
    if (run.code == 0) return const ServeResult.ok();
    return ServeResult.failed(serveError(run.out));
  }

  /// What `tailscale serve` printed when it failed, for the person.
  @visibleForTesting
  static String serveError(String out) {
    // The open source build's daemon runs as root and lets only its operator change Serve.
    if (out.toLowerCase().contains('access denied')) {
      return r'Tailscale didn’t let PocketTerm change its Serve settings. Run sudo tailscale set --operator=$USER '
          'once in a terminal, then check again.';
    }
    final said = out.trim().split('\n').lastWhere((l) => l.trim().isNotEmpty, orElse: () => '').trim();
    return said.isEmpty ? 'tailscale serve failed.' : said;
  }

  /// What already serves on port 443 that isn't the built-in server at
  /// [port] (`tailscale serve status --json`); null when nothing does, or
  /// when the CLI can't say.
  Future<String?> taken(int port) async {
    final cli = _locate();
    if (cli == null) return null;
    try {
      final run = await _run(cli, ['serve', 'status', '--json'], timeout: const Duration(seconds: 10));
      return run.code == 0 ? servedElsewhere(run.out, port) : null;
    } on Object catch (e) {
      debugPrint('PocketTerm: tailscale serve status: $e');
      return null;
    }
  }

  /// The ports a PocketTerm built-in server takes (47900 and the next
  /// ones, should it be taken): a proxy to one of these on 127.0.0.1 is
  /// this app's, from this run or an earlier one.
  static bool _ours(String proxy, int port) {
    final m = RegExp(r'^(?:https?://)?(?:(?:127\.0\.0\.1|localhost):)?(\d+)/?$').firstMatch(proxy.trim());
    final p = m == null ? null : int.parse(m.group(1)!);
    return p != null && (p == port || (p >= 47900 && p < 48000));
  }

  /// [json] (`tailscale serve status --json`, a ServeConfig) read for port
  /// 443: what serves there that isn't the built-in server at [port], in
  /// words; null when nothing else does.
  @visibleForTesting
  static String? servedElsewhere(String json, int port) {
    final Object? config;
    try {
      config = jsonDecode(json.substring(json.indexOf('{').clamp(0, json.length)));
    } on FormatException {
      return null;
    }
    if (config is! Map) return null;
    String? look(Map<dynamic, dynamic> c) {
      if (c['TCP'] case {'443': final Map<dynamic, dynamic> tcp}) {
        if (tcp['TCPForward'] case final String to when to.isNotEmpty) return 'a TCP forward to $to';
        if (tcp['HTTP'] == true) return 'plain HTTP';
      }
      if (c['Web'] case final Map<dynamic, dynamic> web) {
        for (final MapEntry(:key, :value) in web.entries) {
          if (key is! String || !key.endsWith(':443') || value is! Map) continue;
          final handlers = value['Handlers'];
          if (handlers is! Map) continue;
          for (final MapEntry(key: mount, value: h) in handlers.entries) {
            final proxy = h is Map ? h['Proxy'] : null;
            if (mount == '/' && proxy is String && _ours(proxy, port)) continue;
            final what = switch (h) {
              {'Proxy': final String to} => to,
              {'Path': final String path} => path,
              _ => 'a page',
            };
            return mount == '/' ? what : '$what at $mount';
          }
        }
      }
      if (c['Foreground'] case final Map<dynamic, dynamic> sessions) {
        for (final s in sessions.values) {
          if (s is Map) {
            if (look(s) case final what?) return what;
          }
        }
      }
      return null;
    }

    return look(config);
  }

  /// The login.tailscale.com page `tailscale serve` asks for, if it does.
  @visibleForTesting
  static Uri? enableLinkIn(String out) {
    final m = RegExp(r'https://login\.tailscale\.com/\S+').firstMatch(out);
    return m == null ? null : Uri.tryParse(m.group(0)!);
  }

  /// The page that turns HTTPS on for this tailnet, as `tailscale serve`
  /// names it (it asks for it on a tailnet with HTTPS off); the admin
  /// console's DNS page when it names none. A serve that went through
  /// (HTTPS was on after all) is taken back at once.
  Future<Uri> enableHttpsLink({int port = 47900}) async {
    final result = await serve(port);
    if (result.ok) await unserve(port);
    return result.enableLink ?? adminDns;
  }

  /// Stops publishing the built-in server at [port] (`tailscale serve
  /// --https=443 off`), unless port 443 serves something else by now:
  /// that would go with it.
  Future<void> unserve(int port) async {
    final cli = _locate();
    if (cli == null) return;
    if (await taken(port) != null) return;
    try {
      await _run(cli, ['serve', '--https=443', 'off'], timeout: const Duration(seconds: 5));
    } on Object catch (e) {
      debugPrint('PocketTerm: tailscale serve off: $e');
    }
  }

  /// Shows Tailscale's app, to start it or sign in.
  Future<void> open() async {
    try {
      final process = Platform.isWindows
          ? await _start(windowsApp(), const [])
          : await _start('/usr/bin/open', ['-a', 'Tailscale']);
      unawaited(process.exitCode);
    } on Object catch (e) {
      debugPrint('PocketTerm: Tailscale not opened: $e');
    }
  }

  /// Runs [cli] with [args]: its exit code and what it printed (both
  /// streams). Stopped (no code) after [timeout], or once [stopWhen] likes
  /// the output so far.
  Future<({int? code, String out})> _run(
    String cli,
    List<String> args, {
    required Duration timeout,
    bool Function(String out)? stopWhen,
  }) async {
    final process = await _start(cli, args);
    final out = StringBuffer();
    final done = Completer<int?>();
    void add(String s) {
      out.write(s);
      if (!done.isCompleted && (stopWhen?.call(out.toString()) ?? false)) done.complete(null);
    }

    final timer = Timer(timeout, () {
      if (!done.isCompleted) done.complete(null);
    });
    unawaited(
      Future.wait([
            process.stdout.transform(utf8.decoder).forEach(add),
            process.stderr.transform(utf8.decoder).forEach(add),
          ])
          .then((_) => process.exitCode)
          .then(
            (code) {
              if (!done.isCompleted) done.complete(code);
            },
            onError: (Object _) {
              if (!done.isCompleted) done.complete(null);
            },
          ),
    );
    final code = await done.future;
    timer.cancel();
    if (code == null) process.kill();
    return (code: code, out: out.toString());
  }
}
