// A scripted stand-in for omp with PocketTerm's extension in it, for the
// end-to-end run (tool/e2e/run.sh). It speaks the local live API exactly as
// apps/pocketterm-desktop/integrations/omp/pocketterm-live.ts does, draws a
// small omp-like screen in its terminal (title `π > <name>`, an Approve/Deny
// dialog, a spinner while at work) and takes keys like omp: Esc stops a run,
// Ctrl+C empties the editor, Ctrl+D on an empty editor quits, `/new` starts a
// new session in place.
//
// Compiled to an executable named `omp` (the desktop tells agent windows by
// their program's name), on the PATH of the throwaway terminals.
//
//   omp [-c] [--busy] [--ask]
//     -c      carry on the last conversation in this folder
//     --busy  start at work (a spinner), as omp in the middle of a run
//     --ask   start asking to approve a command
//
// The extension counts as installed while
// $HOME/.omp/agent/extensions/pocketterm-live.ts exists when it starts, as
// omp loads extensions once at start. Everything it hears and does goes to
// .fake_omp/log.jsonl in its folder, one JSON object a line, for the harness.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final omp = FakeOmp(
    resume: args.contains('-c') || args.contains('--continue'),
    busy: args.contains('--busy'),
    ask: args.contains('--ask'),
  );
  await omp.run();
}

const _termVars = [
  'TERM_PROGRAM',
  'KITTY_WINDOW_ID',
  'KITTY_PID',
  'KITTY_LISTEN_ON',
  'TMUX',
  'TMUX_PANE',
  'WEZTERM_PANE',
  'WEZTERM_UNIX_SOCKET',
  'ITERM_SESSION_ID',
  'TERM_SESSION_ID',
];

const _spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

const _commands = [
  {'name': 'new', 'description': 'Start a new session'},
  {'name': 'model', 'description': 'Pick the model'},
  {'name': 'resume', 'description': 'Resume a session'},
];

class FakeOmp {
  FakeOmp({required this.resume, required bool busy, required bool ask}) : _startBusy = busy, _startAsk = ask;

  final bool resume;
  final bool _startBusy;
  final bool _startAsk;

  final _env = Platform.environment;
  final _cwd = Directory.current.path;
  late final _dir = Directory(p.join(_cwd, '.fake_omp'))..createSync(recursive: true);
  late final _log = File(p.join(_dir.path, 'log.jsonl'));
  late final _conversation = File(p.join(_dir.path, 'conversation.json'));
  late final String _home = _env['HOME'] ?? '';

  /// PocketTerm's extension, as omp loads it when it starts: there while
  /// the run's throwaway home has it.
  late final bool _extension =
      _env['PTE2E'] == '1' && File(p.join(_home, '.omp', 'agent', 'extensions', 'pocketterm-live.ts')).existsSync();

  late String _sessionId;
  late final String _title = p.basename(_cwd);
  var _items = <Map<String, Object?>>[];
  var _seq = 0;
  bool _busy = false;
  Map<String, Object?>? _ask;
  int _askCursor = 0;
  String _editor = '';
  String? _streaming;
  Timer? _spin;
  int _spinAt = 0;
  WebSocket? _socket;
  bool _connecting = false;
  bool _quitting = false;
  String _tty = '';
  final _queue = <({String text, List<Map<String, Object?>> images})>[];

  void log(String event, [Map<String, Object?> data = const {}]) {
    _log.writeAsStringSync(
      '${jsonEncode({'at': DateTime.now().toIso8601String(), 'pid': pid, 'session': _sessionId, 'event': event, ...data})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  String _newId() => List.generate(8, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  Future<void> run() async {
    _load();
    _tty = await _ttyOf(pid);
    log('start', {'resume': resume, 'extension': _extension, 'tty': _tty, 'cwd': _cwd, 'busy': _startBusy});
    if (stdin.hasTerminal) {
      stdin
        ..echoMode = false
        ..lineMode = false;
    }
    stdout.write('\x1b[?1049h');
    for (final s in [ProcessSignal.sighup, ProcessSignal.sigterm]) {
      s.watch().listen((_) => _quit('signal $s'));
    }
    stdin.listen(_onBytes, onDone: () => _quit('stdin closed'));
    if (_startBusy) _setBusy(true);
    if (_startAsk) _raiseAsk();
    _render();
    if (_extension) unawaited(_connect());
    Timer.periodic(const Duration(seconds: 3), (_) {
      if (_extension && _socket == null) unawaited(_connect());
    });
  }

  // ------------------------------------------------------------ conversation

  void _load() {
    if (resume && _conversation.existsSync()) {
      final json = jsonDecode(_conversation.readAsStringSync()) as Map<String, dynamic>;
      _sessionId = json['id'] as String;
      _items = [for (final i in json['items'] as List) (i as Map).cast<String, Object?>()];
      _seq = json['seq'] as int? ?? _items.length;
    } else {
      _sessionId = _newId();
      _items = [];
    }
  }

  void _save() => _conversation.writeAsStringSync(jsonEncode({'id': _sessionId, 'items': _items, 'seq': _seq}));

  String _itemId() => 'fake-$_sessionId-${++_seq}';

  void _put(Map<String, Object?> item) {
    final i = _items.indexWhere((x) => x['id'] == item['id']);
    if (i < 0) {
      _items.add(item);
    } else {
      _items[i] = item;
    }
    _save();
    _send({'t': 'item', 'item': item});
    _render();
  }

  void _newSession() {
    _sessionId = _newId();
    _items = [];
    _seq = 0;
    _ask = null;
    _save();
    log('new');
    _hello();
    _render();
  }

  // ------------------------------------------------------------ the agent

  void _setBusy(bool busy, {String? summary}) {
    _busy = busy;
    _spin?.cancel();
    _spin = busy ? Timer.periodic(const Duration(milliseconds: 150), (_) => _render(spin: true)) : null;
    _send({'t': 'busy', 'busy': busy, if (!busy && summary != null && summary.isNotEmpty) 'summary': summary});
    _render();
  }

  void _raiseAsk() {
    _ask = {'kind': 'approval', 'id': 'call-${_newId()}', 'tool': 'bash', 'summary': 'echo e2e'};
    _askCursor = 0;
    if (!_busy) _setBusy(true);
    log('ask', {'ask': _ask});
    _send({'t': 'ask', 'ask': _ask});
    _render();
  }

  Future<void> _answerAsk({required bool approve}) async {
    final ask = _ask;
    if (ask == null) return;
    _ask = null;
    log('answered', {'approve': approve, 'ask': ask['id']});
    _send({'t': 'ask', 'ask': null});
    final tool = _itemId();
    _put({
      'id': tool,
      'k': 'tool',
      'tl': 'bash',
      'a': 'echo e2e',
      'st': approve ? 'ok' : 'error',
      'out': approve ? 'e2e' : 'denied',
    });
    await _say(approve ? 'approved' : 'denied');
    _setBusy(false, summary: approve ? 'approved' : 'denied');
  }

  /// A prompt, from the phone ([source] `phone`) or typed here.
  Future<void> _prompt(String text, List<Map<String, Object?>> images, {required String source}) async {
    if (_busy) {
      _queue.add((text: text, images: images));
      log('queued', {'text': text});
      return;
    }
    final described = <Map<String, Object?>>[];
    for (final (n, im) in images.indexed) {
      final bytes = base64Decode(im['data']! as String);
      final mime = im['mimeType'] as String? ?? '';
      final png = bytes.length > 4 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47;
      final jpeg = bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
      final file =
          File(p.join(_dir.path, 'images', '${DateTime.now().millisecondsSinceEpoch}-$n.${png ? 'png' : 'jpg'}'))
            ..createSync(recursive: true)
            ..writeAsBytesSync(bytes);
      described.add({
        'bytes': bytes.length,
        'mime': mime,
        'sha256': sha256.convert(bytes).toString(),
        'decoded': png || jpeg,
        'file': file.path,
      });
    }
    log('prompt', {'text': text, 'source': source, 'images': described});
    _put({'id': _itemId(), 'k': 'user', 't': text, if (images.isNotEmpty) 'im': images.length});
    _setBusy(true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final reply = [
      for (final d in described) 'fake image: ${d['bytes']} bytes ${d['mime']}',
      if (text.trim().isNotEmpty) 'fake reply: ${text.trim()}',
    ].join('\n');
    await _say(reply.isEmpty ? 'fake reply: (nothing)' : reply);
    if (!_busy) return;
    _setBusy(false, summary: reply);
    if (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      unawaited(_prompt(next.text, next.images, source: source));
    }
  }

  /// Streams [text] as an assistant message, as omp does (an item, then appends).
  Future<void> _say(String text) async {
    final id = _itemId();
    _streaming = id;
    final item = <String, Object?>{'id': id, 'k': 'assistant', 't': ''};
    _items.add(item);
    _send({'t': 'item', 'item': item});
    for (var i = 0; i < text.length; i += 12) {
      if (_streaming != id) return;
      final chunk = text.substring(i, min(text.length, i + 12));
      item['t'] = '${item['t']}$chunk';
      _send({'t': 'append', 'id': id, 'text': chunk});
      _render();
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    _streaming = null;
    _save();
  }

  void _abort(String why) {
    if (!_busy) return;
    log('abort', {'why': why});
    _streaming = null;
    _ask = null;
    _send({'t': 'ask', 'ask': null});
    _put({'id': _itemId(), 'k': 'notice', 't': 'Interrupted'});
    _setBusy(false);
  }

  // ------------------------------------------------------------ keys

  void _onBytes(List<int> bytes) {
    var s = utf8.decode(bytes, allowMalformed: true).replaceAll('\x1b[200~', '').replaceAll('\x1b[201~', '');
    while (s.isNotEmpty) {
      String key;
      var take = 1;
      final c = s.codeUnitAt(0);
      if (c == 0x1b) {
        final m = RegExp(r'^\x1b(\[|O)([0-9;]*)([A-Za-z~])').firstMatch(s);
        if (m != null) {
          take = m[0]!.length;
          key = switch (m[3]) {
            'A' => 'up',
            'B' => 'down',
            'C' => 'right',
            'D' => 'left',
            'H' => 'home',
            'F' => 'end',
            'Z' => 'shift+tab',
            _ => 'esc-seq:${m[0]!.substring(1)}',
          };
        } else {
          key = 'esc';
        }
      } else if (c == 0x0d || c == 0x0a) {
        key = 'enter';
      } else if (c == 0x7f || c == 0x08) {
        key = 'backspace';
      } else if (c == 0x03) {
        key = 'ctrl+c';
      } else if (c == 0x04) {
        key = 'ctrl+d';
      } else if (c == 0x09) {
        key = 'tab';
      } else if (c < 0x20) {
        key = 'ctrl+${String.fromCharCode(c + 0x60)}';
      } else {
        final m = RegExp(r'^[^\x00-\x1f\x7f]+').firstMatch(s)!;
        take = m[0]!.length;
        _typed(m[0]!);
        s = s.substring(take);
        continue;
      }
      s = s.substring(take);
      _key(key);
    }
  }

  void _typed(String text) {
    log('text', {'text': text});
    if (_ask != null) return;
    _editor += text;
    _render();
  }

  void _key(String key) {
    log('key', {'key': key});
    if (_ask != null) {
      switch (key) {
        case 'up':
          _askCursor = 0;
        case 'down':
          _askCursor = 1;
        case 'enter':
          unawaited(_answerAsk(approve: _askCursor == 0));
        case 'esc':
          _abort('esc');
      }
      _render();
      return;
    }
    switch (key) {
      case 'esc':
        _abort('esc');
      case 'ctrl+c':
        _editor = '';
      case 'ctrl+d':
        if (_editor.isEmpty) return _quit('ctrl+d');
      case 'backspace':
        if (_editor.isNotEmpty) _editor = _editor.substring(0, _editor.length - 1);
      case 'enter':
        final text = _editor.trim();
        _editor = '';
        if (text.isEmpty) break;
        if (text.startsWith('/')) {
          log('command', {'command': text});
          if (text == '/new') _newSession();
          break;
        }
        unawaited(_prompt(text, const [], source: 'keyboard'));
    }
    _render();
  }

  // ------------------------------------------------------------ screen

  void _render({bool spin = false}) {
    if (_quitting) return;
    if (spin) _spinAt = (_spinAt + 1) % _spinner.length;
    final state = _ask != null ? '!' : (_busy ? _spinner[_spinAt] : '>');
    final out = StringBuffer()
      ..write('\x1b]2;π $state $_title\x07')
      ..write('\x1b[H\x1b[2J')
      ..writeln('fake omp · $_title · session ${_sessionId.substring(0, 6)} · PocketTerm ${_extension ? 'on' : 'off'}')
      ..writeln('─' * 40);
    final rows = stdout.hasTerminal ? stdout.terminalLines : 24;
    final lines = <String>[];
    for (final i in _items) {
      final who = switch (i['k']) {
        'user' => 'you',
        'assistant' => 'omp',
        'tool' => 'tool',
        _ => '·',
      };
      final text = i['k'] == 'tool' ? '${i['tl']}: ${i['a']} → ${i['out']}' : '${i['t'] ?? ''}';
      for (final l in text.split('\n')) {
        lines.add('$who: $l');
      }
    }
    final room = max(1, rows - 10);
    for (final l in lines.skip(max(0, lines.length - room))) {
      out.writeln(l);
    }
    out.writeln('─' * 40);
    if (_ask case final ask?) {
      out
        ..writeln('Allow ${ask['tool']}: ${ask['summary']}')
        ..writeln('${_askCursor == 0 ? '❯' : ' '} Approve')
        ..writeln('${_askCursor == 1 ? '❯' : ' '} Deny');
    } else if (_busy) {
      out.writeln('${_spinner[_spinAt]} Working… (esc to interrupt)');
    }
    out.write('> $_editor');
    stdout.write(out);
  }

  // ------------------------------------------------------------ PocketTerm

  /// Only the run's own desktop app: the throwaway shell names its cli.json.
  /// Outside it (no `PTE2E`, or no cli.json named) the fake omp reaches no
  /// PocketTerm at all, so it never reports to a real one.
  File? get _cliFile {
    final named = _env['POCKETTERM_CLI_JSON'];
    if (_env['PTE2E'] != '1' || named == null || named.isEmpty) return null;
    return File(named);
  }

  Future<void> _connect() async {
    if (_connecting || _socket != null || _quitting) return;
    _connecting = true;
    try {
      final f = _cliFile;
      if (f == null || !f.existsSync()) return;
      final cli = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final port = cli['port'] as int;
      final token = cli['token'] as String;
      if (!await _proven(port, token)) {
        log('unproven', {'port': port});
        return;
      }
      final ws = await WebSocket.connect(
        'ws://127.0.0.1:$port/v1/live',
        headers: {'authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 3));
      _socket = ws;
      log('connected', {'port': port});
      _hello();
      if (_ask != null) _send({'t': 'ask', 'ask': _ask});
      ws.listen(
        (f) => f is String ? unawaited(_onFrame(f)) : null,
        onDone: () {
          if (identical(_socket, ws)) _socket = null;
          log('disconnected');
        },
        onError: (Object _) {},
        cancelOnError: true,
      );
    } on Object catch (e) {
      log('connect failed', {'error': '$e'});
    } finally {
      _connecting = false;
    }
  }

  Future<bool> _proven(int port, String token) async {
    final nonce = _newId() + _newId();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.get('127.0.0.1', port, '/v1/ping?nonce=$nonce');
      final res = await req.close().timeout(const Duration(seconds: 3));
      final body = jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
      final want = Hmac(sha256, utf8.encode(token)).convert(utf8.encode('pocketterm-ping\n$port\n$nonce')).toString();
      return res.statusCode == 200 && body['app'] == 'pocketterm' && body['proof'] == want;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void _send(Map<String, Object?> frame) {
    final ws = _socket;
    if (ws == null || ws.readyState != WebSocket.open) return;
    ws.add(jsonEncode(frame));
  }

  String? get _windowKey {
    final listen = _env['KITTY_LISTEN_ON'];
    final id = _env['KITTY_WINDOW_ID'];
    if (listen == null || id == null || listen.isEmpty || id.isEmpty) return null;
    return '${p.basename(listen.replaceFirst('unix:', ''))}/$id';
  }

  Map<String, String> get _term => {
    for (final v in _termVars)
      if (_env[v] case final value? when value.isNotEmpty) v: value,
    if (_tty.isNotEmpty) 'tty': '/dev/$_tty',
  };

  void _hello() {
    _send({
      't': 'hello',
      'v': 1,
      'agent': 'omp',
      'session': {'id': _sessionId, 'title': _title, 'cwd': _cwd, 'model': 'fake-model'},
      'window': _windowKey,
      'term': _term,
      'pid': pid,
      'busy': _busy,
      'ctx': 1,
      'items': _items.length > 300 ? _items.sublist(_items.length - 300) : _items,
      'older': false,
      'commands': _commands,
    });
    log('hello', {'items': _items.length, 'term': _term});
  }

  Future<void> _onFrame(String text) async {
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(text) as Map<String, dynamic>;
    } on FormatException {
      return;
    }
    final req = m['req'];
    void reply([Map<String, Object?> body = const {}]) => _send({'t': 'reply', 'req': req, ...body});
    switch (m['t']) {
      case 'prompt':
        final images = [for (final i in m['images'] as List? ?? const []) (i as Map).cast<String, Object?>()];
        final words = m['text'] as String? ?? '';
        if (words.trim().isEmpty && images.isEmpty) return reply({'error': 'Nothing to send.'});
        reply();
        await _prompt(words, images, source: 'phone');
      case 'abort':
        _abort('phone');
        reply();
      case 'older':
        reply({'items': const <Object>[], 'older': false});
      default:
        log('unknown frame', {'frame': m});
        reply({'error': 'Unknown request: ${m['t']}'});
    }
  }

  // ------------------------------------------------------------ the end

  Future<String> _ttyOf(int pid) async {
    try {
      final r = await Process.run('/bin/ps', ['-o', 'tty=', '-p', '$pid']);
      final t = '${r.stdout}'.trim();
      return RegExp(r'^ttys\d+$').hasMatch(t) ? t : '';
    } on Object {
      return '';
    }
  }

  void _quit(String why) {
    if (_quitting) return;
    _quitting = true;
    log('quit', {'why': why});
    _spin?.cancel();
    unawaited(_socket?.close());
    stdout.write('\x1b[?1049l');
    if (stdin.hasTerminal) {
      try {
        stdin
          ..lineMode = true
          ..echoMode = true;
      } on Object {
        // The terminal has gone.
      }
    }
    exit(0);
  }
}
