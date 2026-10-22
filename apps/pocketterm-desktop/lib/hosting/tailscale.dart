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
  const ServeResult.ok() : enableLink = null, error = null;
  const ServeResult.needsHttps(Uri this.enableLink) : error = null;
  const ServeResult.failed(String this.error) : enableLink = null;

  /// The tailnet has HTTPS (Serve) off: the page that turns it on.
  final Uri? enableLink;

  /// What the CLI said when it failed otherwise.
  final String? error;

  bool get ok => enableLink == null && error == null;
}

/// The Tailscale CLI: whether Tailscale runs here and under which name, and
/// `tailscale serve`, which publishes the built-in server at
/// `https://<this computer>.<tailnet>.ts.net` to the tailnet only.
class Tailscale {
  Tailscale({StartProcess? start, String? Function()? locate})
    : _start = start ?? Process.start,
      _locate = locate ?? findCli;

  final StartProcess _start;
  final String? Function() _locate;

  /// Where to get Tailscale.
  static final Uri download = Uri.parse('https://tailscale.com/download');

  /// The admin console's DNS page: MagicDNS and HTTPS certificates.
  static final Uri adminDns = Uri.parse('https://login.tailscale.com/admin/dns');

  /// The Mac app's CLI.
  static const macCli = '/Applications/Tailscale.app/Contents/MacOS/Tailscale';

  /// Windows' CLI, and the app that shows Tailscale's window.
  static const windowsCli = r'C:\Program Files\Tailscale\tailscale.exe';
  static const windowsApp = r'C:\Program Files\Tailscale\tailscale-ipn.exe';

  /// The CLI: the app's own on a Mac or Windows, else `tailscale` on the
  /// PATH (a GUI app's PATH is short, so Homebrew's folders too). Null when
  /// Tailscale isn't installed.
  static String? findCli({Map<String, String>? env, bool Function(String path)? exists, bool? windows}) {
    final isFile = exists ?? (String path) => File(path).existsSync();
    final win = windows ?? Platform.isWindows;
    final vars = env ?? Platform.environment;
    final app = win ? windowsCli : macCli;
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
  Future<ServeResult> serve(int port) async {
    final cli = _locate();
    if (cli == null) return const ServeResult.failed('Tailscale isn’t installed.');
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
    final said = run.out.trim().split('\n').lastWhere((l) => l.trim().isNotEmpty, orElse: () => '').trim();
    return ServeResult.failed(said.isEmpty ? 'tailscale serve failed.' : said);
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
    if (result.ok) await unserve();
    return result.enableLink ?? adminDns;
  }

  /// Stops publishing the built-in server (`tailscale serve --https=443 off`).
  Future<void> unserve() async {
    final cli = _locate();
    if (cli == null) return;
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
          ? await _start(windowsApp, const [])
          : await _start('open', ['-a', 'Tailscale']);
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
