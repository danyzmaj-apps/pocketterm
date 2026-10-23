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
// A prompt, typed here or from the phone, gets `fake reply: <text>` (and a
// line for each image or @file it carries). A prompt with:
//   e2e-slow      works for 90 s first; Esc or the phone's Stop ends it
//   e2e-question  asks which color (Red, Green, Blue or a typed Other) and
//                 replies `fake answer: <answer>`
//   e2e-plan      shows plan mode's review (Approve and execute, Refine the
//                 plan, Stay in plan mode); replies `fake plan: <option>`
// A phone prompt while at work is a steer unless it says followUp: a steer
// shows at once and gets `fake steered: <text>` as the run ends; a follow-up
// waits its turn and runs as a prompt of its own, as does one typed here.
// `/model` opens a picker of fake-model, fake-model-fast and fake-model-slow;
// `/resume` one of three sessions, narrowed by what's typed. Enter picks,
// Esc closes. Each draws as omp's do, so PocketTerm reads it off the screen.
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

/// The /model picker's rows: a model and what it's for.
const _models = [
  ('fake-model', 'the default'),
  ('fake-model-fast', 'quick replies'),
  ('fake-model-slow', 'careful replies'),
];

/// The /resume picker's rows: a past session and its size.
const _sessions = [
  ('e2e alpha session', '3 messages'),
  ('e2e beta session', '5 messages'),
  ('e2e gamma session', '8 messages'),
];

/// What `e2e-question` asks, and the answers it offers before Other.
const _question = 'Which color should the e2e button be?';
const _colors = ['Red', 'Green', 'Blue'];

/// The plan review's options, top to bottom.
const _planOptions = ['Approve and execute', 'Refine the plan', 'Stay in plan mode'];

/// A picker a slash command opened: its rows (label, detail), the row its
/// cursor is on and, in one that searches, what was typed.
class _Picker {
  _Picker(this.menu, this.title, this.all, {this.cursor = 0, this.search = false});

  final String menu;
  final String title;
  final List<(String, String)> all;
  final bool search;
  int cursor;
  String query = '';

  /// The rows whose label holds the search, in any case.
  List<(String, String)> get rows => [
    for (final r in all)
      if (r.$1.toLowerCase().contains(query.toLowerCase())) r,
  ];
}

class FakeOmp {
  FakeOmp({required this.resume, required bool busy, required bool ask}) : _startBusy = busy, _startAsk = ask;

  final bool resume;
  final bool _startBusy;
  final bool _startAsk;

  final Map<String, String> _env = Platform.environment;
  final String _cwd = Directory.current.path;
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

  /// The ask up now: an approval, the color question or the plan review.
  Map<String, Object?>? _ask;
  int _askCursor = 0;

  /// The question's Other answer while it's being typed.
  String? _other;
  _Picker? _picker;
  String _model = 'fake-model';
  String _editor = '';
  String? _streaming;
  Timer? _spin;
  int _spinAt = 0;
  WebSocket? _socket;
  bool _connecting = false;
  bool _quitting = false;
  String _tty = '';

  /// The run at work: a new prompt and an abort each start another, so an
  /// old run that wakes up knows it's over.
  int _run = 0;
  final _steers = <String>[];
  final _queue = <({String text, List<Map<String, Object?>> images, String source})>[];

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
    // The terminal still turns Ctrl+C into SIGINT (only canonical mode is
    // off); omp takes it as a key, so this does too.
    ProcessSignal.sigint.watch().listen((_) => _key('ctrl+c'));
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
    _other = null;
    _picker = null;
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

  /// Puts [ask] up, on the screen and to PocketTerm, at work until it's answered.
  void _raise(Map<String, Object?> ask) {
    _ask = ask;
    _askCursor = 0;
    _other = null;
    if (!_busy) _setBusy(true);
    log('ask', {'ask': ask});
    _send({'t': 'ask', 'ask': ask});
    _render();
  }

  void _raiseAsk() => _raise({'kind': 'approval', 'id': 'call-${_newId()}', 'tool': 'bash', 'summary': 'echo e2e'});

  void _raiseQuestion() => _raise({
    'kind': 'ask',
    'id': 'call-${_newId()}',
    'questions': [
      {
        'id': 'color',
        'header': 'Color',
        'question': _question,
        'options': [for (final c in _colors) {'label': c}],
      },
    ],
  });

  void _raisePlan() => _raise({'kind': 'plan', 'id': 'call-${_newId()}', 'title': 'e2e plan'});

  /// Takes the ask down, on the screen and at PocketTerm.
  void _dropAsk() {
    _ask = null;
    _other = null;
    _send({'t': 'ask', 'ask': null});
  }

  Future<void> _answerAsk({required bool approve}) async {
    final ask = _ask;
    if (ask == null) return;
    final run = _run;
    _dropAsk();
    log('answered', {'approve': approve, 'ask': ask['id']});
    final tool = _itemId();
    _put({
      'id': tool,
      'k': 'tool',
      'tl': 'bash',
      'a': 'echo e2e',
      'st': approve ? 'ok' : 'error',
      'out': approve ? 'e2e' : 'denied',
    });
    await _finish(run, approve ? 'approved' : 'denied');
  }

  Future<void> _answerQuestion(String answer, {required bool custom}) async {
    if (_ask == null) return;
    final run = _run;
    _dropAsk();
    log('question-answered', {'answer': answer, 'custom': custom});
    await _finish(run, 'fake answer: $answer');
  }

  Future<void> _pickPlan(String option) async {
    if (_ask == null) return;
    final run = _run;
    _dropAsk();
    log('plan-picked', {'option': option});
    await _finish(run, 'fake plan: $option');
  }

  /// A prompt, from the phone ([source] `phone`) or typed here. While at
  /// work a [steer] shows at once and is answered as the run ends; any
  /// other waits its turn.
  Future<void> _prompt(
    String text,
    List<Map<String, Object?>> images, {
    required String source,
    bool steer = false,
  }) async {
    if (_busy) {
      if (steer) {
        _steers.add(text);
        log('steer', {'text': text});
        _put({'id': _itemId(), 'k': 'user', 't': text, if (images.isNotEmpty) 'im': images.length});
      } else {
        _queue.add((text: text, images: images, source: source));
        log('queued', {'text': text});
      }
      return;
    }
    final run = ++_run;
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
    // Files named as @path (or @"path"), read in as omp does at rest.
    final files = [
      for (final m in RegExp(r'''(?:^|[\s(\[{<"'`])@(?:"([^"]+)"|'([^']+)'|([^\s@]+))''').allMatches(text))
        if (File(m[1] ?? m[2] ?? m[3]!) case final f when f.existsSync())
          {
            'path': f.path,
            'name': p.basename(f.path),
            'bytes': f.lengthSync(),
            'sha256': sha256.convert(f.readAsBytesSync()).toString(),
          },
    ];
    log('prompt', {'text': text, 'source': source, 'images': described, 'files': files});
    _put({'id': _itemId(), 'k': 'user', 't': text, if (images.isNotEmpty) 'im': images.length});
    _setBusy(true);
    if (text.contains('e2e-question')) return _raiseQuestion();
    if (text.contains('e2e-plan')) return _raisePlan();
    // Long enough for a phone flow to steer and queue while it works (each
    // Maestro step in the Simulator takes seconds).
    final work = text.contains('e2e-slow') ? const Duration(seconds: 90) : const Duration(milliseconds: 400);
    final until = DateTime.now().add(work);
    while (DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (run != _run) return;
    }
    final reply = [
      for (final d in described) 'fake image: ${d['bytes']} bytes ${d['mime']}',
      for (final f in files) 'fake file: ${f['name']} ${f['bytes']} bytes',
      if (text.trim().isNotEmpty) 'fake reply: ${text.trim()}',
    ].join('\n');
    await _finish(run, reply.isEmpty ? 'fake reply: (nothing)' : reply);
  }

  /// Ends [run]: says [reply], then answers each steer that came during it,
  /// goes idle and starts the next prompt waiting. Nothing once it's over.
  Future<void> _finish(int run, String reply) async {
    var last = reply;
    await _say(reply);
    while (run == _run && _steers.isNotEmpty) {
      last = 'fake steered: ${_steers.removeAt(0)}';
      await _say(last);
    }
    if (run != _run || !_busy) return;
    _setBusy(false, summary: last);
    if (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      unawaited(_prompt(next.text, next.images, source: next.source));
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
    _run++;
    _steers.clear();
    _streaming = null;
    _dropAsk();
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
    if (_picker case final picker?) {
      if (picker.search) {
        picker
          ..query += text
          ..cursor = 0;
        _render();
      }
      return;
    }
    if (_ask != null) {
      if (_other case final other?) {
        _other = other + text;
        _render();
      }
      return;
    }
    _editor += text;
    _render();
  }

  void _key(String key) {
    log('key', {'key': key});
    if (_picker case final picker?) {
      _pickerKey(picker, key);
    } else if (_ask case final ask?) {
      _askKey(ask, key);
    } else {
      _editorKey(key);
    }
    _render();
  }

  /// A picker's keys: ↑/↓ move, Backspace edits the search, Enter picks,
  /// Esc (or Ctrl+C) closes it.
  void _pickerKey(_Picker picker, String key) {
    final rows = picker.rows;
    switch (key) {
      case 'up':
        picker.cursor = max(0, picker.cursor - 1);
      case 'down':
        picker.cursor = max(0, min(rows.length - 1, picker.cursor + 1));
      case 'backspace':
        if (picker.search && picker.query.isNotEmpty) {
          picker
            ..query = picker.query.substring(0, picker.query.length - 1)
            ..cursor = 0;
        }
      case 'enter':
        if (rows.isEmpty) return;
        final label = rows[picker.cursor].$1;
        _picker = null;
        if (picker.menu == 'model') {
          _model = label;
          log('model', {'model': label});
        } else {
          log('resume', {'session': label});
        }
      case 'esc' || 'ctrl+c':
        _picker = null;
        log('menu-cancel', {'menu': picker.menu});
    }
  }

  /// An ask's keys: ↑/↓ move (stopping at the ends), Enter answers, Esc
  /// stops the run. The question's Other row opens typing on Enter; its
  /// next Enter answers with what was typed, and Esc goes back to the rows.
  void _askKey(Map<String, Object?> ask, String key) {
    if (_other case final other?) {
      switch (key) {
        case 'enter':
          if (other.trim().isNotEmpty) unawaited(_answerQuestion(other.trim(), custom: true));
        case 'backspace':
          if (other.isNotEmpty) _other = other.substring(0, other.length - 1);
        case 'esc':
          _other = null;
      }
      return;
    }
    final rows = switch (ask['kind']) {
      'approval' => 2,
      'plan' => _planOptions.length,
      _ => _colors.length + 1,
    };
    switch (key) {
      case 'up':
        _askCursor = max(0, _askCursor - 1);
      case 'down':
        _askCursor = min(rows - 1, _askCursor + 1);
      case 'enter':
        switch (ask['kind']) {
          case 'approval':
            unawaited(_answerAsk(approve: _askCursor == 0));
          case 'plan':
            unawaited(_pickPlan(_planOptions[_askCursor]));
          default:
            if (_askCursor < _colors.length) {
              unawaited(_answerQuestion(_colors[_askCursor], custom: false));
            } else {
              _other = '';
            }
        }
      case 'esc':
        _abort('esc');
    }
  }

  void _editorKey(String key) {
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
          switch (text) {
            case '/new':
              _newSession();
            case '/model':
              _picker = _Picker('model', 'Select a model', _models, cursor: _models.indexWhere((m) => m.$1 == _model));
            case '/resume':
              _picker = _Picker('resume', 'Resume a session', _sessions, search: true);
          }
          break;
        }
        unawaited(_prompt(text, const [], source: 'keyboard'));
    }
  }

  // ------------------------------------------------------------ screen

  void _render({bool spin = false}) {
    if (_quitting) return;
    if (spin) _spinAt = (_spinAt + 1) % _spinner.length;
    final state = _ask != null ? '!' : (_busy ? _spinner[_spinAt] : '>');
    stdout.write('\x1b]2;π $state $_title\x07\x1b[H\x1b[2J${_screen()}');
  }

  /// The screen's text, as the terminal shows it. A picker, the question or
  /// the plan review is drawn as omp draws it, so PocketTerm reads it back
  /// (pocketterm_core's parseMenu, parsePlanReview and askOnScreen): its
  /// title right above its rows, the cursor row `  ❯ <label>`, the others
  /// indented as far, a picker's detail two spaces past its label, and no
  /// editor line. /resume's search goes on a `> ` line between its title
  /// and its rows.
  String _screen() {
    final out = StringBuffer()
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
    final room = max(1, rows - 12);
    lines.skip(max(0, lines.length - room)).forEach(out.writeln);
    out.writeln('─' * 40);
    // A row of a list whose cursor is on row [at].
    String row(int i, int at, String text) => '${i == at ? '  ❯ ' : '    '}$text';
    if (_picker case final picker?) {
      out.writeln(picker.title);
      if (picker.search) out.writeln('> ${picker.query}');
      final shown = picker.rows;
      if (shown.isEmpty) out.writeln('No match');
      for (final (i, (label, detail)) in shown.indexed) {
        out.writeln(row(i, picker.cursor, '$label  $detail'));
      }
      out.write('↑/↓ move · ⏎ pick · esc cancel');
    } else if (_ask case final ask?) {
      switch (ask['kind']) {
        case 'approval':
          out
            ..writeln('Allow ${ask['tool']}: ${ask['summary']}')
            ..writeln('${_askCursor == 0 ? '❯' : ' '} Approve')
            ..writeln('${_askCursor == 1 ? '❯' : ' '} Deny')
            ..write('> $_editor');
        case 'plan':
          out
            ..writeln('Plan: ${ask['title']}')
            ..writeln('Plan mode - next step');
          for (final (i, o) in _planOptions.indexed) {
            out.writeln(row(i, _askCursor, o));
          }
          out.write('↑/↓ select · ⏎ confirm · esc cancel');
        default:
          out
            ..writeln('Color')
            ..writeln(_question);
          for (final (i, c) in [..._colors, 'Other'].indexed) {
            out.writeln(row(i, _askCursor, i == _colors.length && _other != null ? 'Other: $_other' : c));
          }
          out.write(_other != null ? '⏎ answer · esc back' : '↑/↓ move · ⏎ pick · esc cancel');
      }
    } else {
      if (_busy) out.writeln('${_spinner[_spinAt]} Working… (esc to interrupt)');
      out.write('> $_editor');
    }
    return out.toString();
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
      'session': {'id': _sessionId, 'title': _title, 'cwd': _cwd, 'model': _model},
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
        await _prompt(words, images, source: 'phone', steer: m['deliver'] != 'followUp');
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
