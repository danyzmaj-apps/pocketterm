import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_desktop/hosting/tailscale.dart';
import 'package:pocketterm_server/pocketterm_server.dart';

/// Where the built-in server stands, for the person: what to do next.
enum HostState {
  /// Looking at Tailscale for the first time.
  checking,

  /// Tailscale isn't installed: Install.
  noTailscale,

  /// Tailscale isn't running or is switched off: Open Tailscale.
  tailscaleOff,

  /// Tailscale is signed out: Open Tailscale.
  loggedOut,

  /// The tailnet has HTTPS off (or MagicDNS): the page that turns it on.
  httpsOff,

  /// `tailscale serve` failed for another reason ([BuiltInServer.error]).
  failed,

  /// Port 443 of this computer's Tailscale name serves something else,
  /// left alone ([BuiltInServer.error] says what).
  taken,

  /// Phones reach it at [BuiltInServer.publicUrl].
  ready,
}

/// The PocketTerm server built into the app ("This computer"): it listens
/// on 127.0.0.1 only, and Tailscale publishes it to the owner's tailnet at
/// `https://<this computer>.<tailnet>.ts.net` (`tailscale serve`), so
/// phones get real HTTPS and nothing else on the network reaches it. This
/// computer signs itself in on 127.0.0.1 with the server's own setup token.
class BuiltInServer extends ChangeNotifier {
  BuiltInServer({
    required this.dataDir,
    required this.tailscale,
    this.recheck = const Duration(seconds: 10),
    this.recheckReady = const Duration(minutes: 1),
    this.relay,
    this.relayKey,
  });

  /// The server's data (app support `pocketterm-server/`).
  final Directory dataDir;
  final Tailscale tailscale;

  /// How often Tailscale is looked at again while it isn't serving, and
  /// once it is (it may sign out, or the computer get another name).
  /// [Duration.zero]: only when asked ([refresh]).
  final Duration recheck;
  final Duration recheckReady;

  /// The push relay and its key; the publisher's by default.
  final Uri? relay;
  final List<int>? relayKey;

  PocketTermServer? _server;
  Timer? _timer;

  /// Running (between [start] and [stop]).
  bool get running => _server != null;

  /// The port it listens on, on 127.0.0.1.
  int get port => _server!.port;

  /// How this computer reaches it: `http://127.0.0.1:<port>`.
  Backend get backend => Backend(url: 'http://127.0.0.1:$port');

  /// What Tailscale said last; null before the first look.
  TailscaleStatus? get tailscaleStatus => _status;
  TailscaleStatus? _status;

  /// Where phones and other computers reach it, while Tailscale serves it.
  Uri? get publicUrl => _served;
  Uri? _served;

  /// The tailnet's page that turns HTTPS on, when `tailscale serve` asked
  /// for it.
  Uri? get enableHttps => _enableHttps;
  Uri? _enableHttps;

  /// What `tailscale serve` said when it failed otherwise.
  String? get error => _error;
  String? _error;
  bool _taken = false;

  /// This computer's address before Tailscale gave it another one (the
  /// computer was renamed, or Tailscale signed in to another tailnet):
  /// phones and computers set up with it can't reach this one any more.
  /// Kept until [renameSeen].
  Uri? get renamedFrom {
    final f = File('${dataDir.path}/$_renamedFile');
    final old = f.existsSync() ? Uri.tryParse(f.readAsStringSync().trim()) : null;
    return old == null || old.host.isEmpty ? null : old;
  }

  static const _servedFile = 'tailscale_url';
  static const _renamedFile = 'tailscale_renamed_from';

  /// The person has seen [renamedFrom]: it goes.
  void renameSeen() {
    final f = File('${dataDir.path}/$_renamedFile');
    if (f.existsSync()) f.deleteSync();
    notifyListeners();
  }

  /// Tailscale serves it at [url] now; another address before means a
  /// rename. Renamed again before that was seen, the first address stays:
  /// it's the one the phones have.
  void _servedAt(Uri url) {
    try {
      final served = File('${dataDir.path}/$_servedFile');
      final renamed = File('${dataDir.path}/$_renamedFile');
      final before = served.existsSync() ? served.readAsStringSync().trim() : '';
      if (before.isNotEmpty && before != '$url' && renamedFrom == null) renamed.writeAsStringSync(before);
      // Back at the old name: nothing changed for the phones after all.
      if (renamedFrom == url) renamed.deleteSync();
      served.writeAsStringSync('$url');
    } on FileSystemException catch (e) {
      debugPrint('PocketTerm: Tailscale address not kept: $e');
    }
  }

  HostState get state {
    final s = _status;
    if (s == null) return HostState.checking;
    return switch (s.state) {
      TailscaleState.missing => HostState.noTailscale,
      TailscaleState.stopped => HostState.tailscaleOff,
      TailscaleState.loggedOut => HostState.loggedOut,
      TailscaleState.running when _served != null => HostState.ready,
      TailscaleState.running when _taken => HostState.taken,
      TailscaleState.running when _error != null => HostState.failed,
      TailscaleState.running => HostState.httpsOff,
    };
  }

  /// Starts listening on 127.0.0.1:[port], or the next free port above it
  /// (up to 20 more), then has Tailscale publish it.
  Future<void> start({int port = 47900}) async {
    if (_server != null) return;
    SocketException? last;
    for (var p = port; p < port + 20; p++) {
      try {
        _server = await PocketTermServer.start(
          dataDir: dataDir,
          address: InternetAddress.loopbackIPv4,
          port: p,
          // Setup links carry the Tailscale address (setupLink), never this.
          publicUrl: Uri.parse('http://127.0.0.1:$p'),
          relay: relay,
          relayKey: relayKey,
          // tailscale serve forwards from 127.0.0.1 with the tailnet caller in X-Forwarded-For: each gets its
          // own redeem throttle instead of one shared by everyone.
          trustLoopbackProxy: true,
          log: (m) => debugPrint('PocketTerm server: $m'),
        );
        break;
      } on SocketException catch (e) {
        last = e;
      }
    }
    if (_server == null) throw last ?? const SocketException('No free port for the server.');
    notifyListeners();
    // Tailscale may take a while (serve waits up to 30 seconds); the server
    // works on 127.0.0.1 meanwhile.
    unawaited(refresh());
  }

  /// Looks at Tailscale again and has it publish the server when it can
  /// (again when this computer's name changed). A call while one runs
  /// waits for that one.
  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void>? _refreshing;

  Future<void> _refresh() async {
    if (_server == null) return;
    final status = await tailscale.status();
    if (_server == null) return;
    _status = status;
    final url = status.url;
    if (status.state != TailscaleState.running || url == null) {
      _served = null;
      _enableHttps = null;
      _error = null;
      _taken = false;
    } else if (_served != url) {
      final result = await tailscale.serve(port);
      if (_server == null) return;
      _served = result.ok ? url : null;
      _enableHttps = result.enableLink;
      _error = result.error;
      _taken = result.taken != null;
      if (result.ok) _servedAt(url);
    } else if (await tailscale.taken(port) case final what?) {
      // Something else took port 443 since: it stays, and phones can't reach this one.
      if (_server == null) return;
      _served = null;
      _error = ServeResult.taken(what).error;
      _taken = true;
    }
    _schedule();
    notifyListeners();
  }

  void _schedule() {
    _timer?.cancel();
    final every = state == HostState.ready ? recheckReady : recheck;
    if (every > Duration.zero) _timer = Timer(every, () => unawaited(refresh()));
  }

  /// Stops publishing it on the tailnet and stops it.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final server = _server;
    if (server == null) return;
    _server = null;
    final served = _served != null;
    _served = null;
    _status = null;
    _enableHttps = null;
    _error = null;
    _taken = false;
    await Future.wait([if (served) tailscale.unserve(server.port), server.stop()]);
    notifyListeners();
  }

  /// The link another computer sets up with ("Add a computer…"): the
  /// Tailscale address and the server's setup token. Null until Tailscale
  /// serves it.
  Uri? setupLink() => _served == null ? null : PocketTermServer.setupLinkFor(dataDir, _served!);

  /// The same for this computer itself, on 127.0.0.1.
  Uri ownSetupLink() => PocketTermServer.setupLinkFor(dataDir, Uri.parse(backend.url));

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
