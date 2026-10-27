import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/desktops.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal_remote.dart';

// "Try the demo": the real app on a made-up computer, answered right here on
// the phone. Two projects with coding sessions (one finished, one waiting for
// an approval, one at work), their conversations and plain terminal windows.
// Nothing goes over the network. The docs' screenshots draw the same data.

const demoHome = '/Users/demo';
const demoGarden = '$demoHome/Dev/garden-api';
const demoSite = '$demoHome/Dev/pocketterm-site';

/// The pretend computer's id and name.
const demoDesktopId = 'demo0000';
const demoDesktopName = 'MacBook Pro';

/// A window that shows only its screen (omp at work in it, not reporting).
const demoScreenOnly = 'kitty-1/7';

/// What every op the demo can't pretend says.
const demoNoComputer =
    "This is the demo, so there's no computer to do that. Scan your computer's code to use PocketTerm for real.";

/// The sessions, as the computer sends them in its state; [overrides] by session key.
List<Map<String, dynamic>> _sessions(DateTime now, Map<String, Map<String, dynamic>> overrides) {
  int ago(int minutes) => now.subtract(Duration(minutes: minutes)).millisecondsSinceEpoch;
  return [
    for (final s in [
      {
        'key': 'kitty-1/3',
        'id': 's1',
        'agent': 'omp',
        'window': 'kitty-1/3',
        'title': 'Add a soil moisture endpoint',
        'cwd': demoGarden,
        'model': 'Sonnet 4.5',
        'ctx': 23,
        'cost': 1.86,
        'at': ago(4),
        'epoch': 'e1',
        'seq': 7,
      },
      {
        'key': 'wezterm-2',
        'id': 's2',
        'agent': 'claude',
        'window': 'wezterm-2',
        'title': 'Fix the pricing table on small screens',
        'cwd': demoSite,
        'model': 'Opus 4.5',
        'ctx': 61,
        'cost': 12.4,
        'ask': {'kind': 'approval', 'id': 'a1', 'tool': 'Bash', 'summary': 'npm run build'},
        'at': ago(1),
        'epoch': 'e1',
        'seq': 4,
      },
      {
        'key': 'tmux-%4',
        'id': 's3',
        'agent': 'omp',
        'window': 'tmux-%4',
        'title': 'Rate-limit the plant search',
        'cwd': demoGarden,
        'model': 'GPT-5.5',
        'busy': true,
        'ctx': 84,
        'cost': 43.34,
        'at': ago(0),
        'epoch': 'e1',
        'seq': 5,
      },
    ])
      {...s, ...?overrides[s['key']]},
  ];
}

/// The computer's state: three coding sessions (finished, needing you,
/// working), a window showing only its screen and three plain terminal
/// windows, in two projects.
Map<String, dynamic> demoState({DateTime? now, Map<String, Map<String, dynamic>> overrides = const {}}) => {
  'windows': [
    {'key': 'kitty-1/3', 'title': 'omp', 'cwd': demoGarden, 'program': 'omp', 'app': 'kitty'},
    {'key': 'wezterm-2', 'title': 'claude', 'cwd': demoSite, 'program': 'claude', 'app': 'wezterm'},
    {'key': 'tmux-%4', 'title': 'omp', 'cwd': demoGarden, 'program': 'omp', 'app': 'tmux', 'via': 'Ghostty'},
    {'key': 'kitty-1/1', 'title': 'zsh', 'cwd': demoGarden, 'program': 'zsh', 'app': 'kitty', 'focused': true},
    {'key': 'tmux-%2', 'title': 'nvim README.md', 'cwd': demoSite, 'program': 'nvim', 'app': 'tmux', 'via': 'Ghostty'},
    {'key': demoScreenOnly, 'title': 'omp', 'cwd': demoGarden, 'program': 'omp', 'app': 'kitty'},
  ],
  'sessions': _sessions(now ?? DateTime.now(), overrides),
  'projects': [demoGarden, demoSite],
  'home': demoHome,
  'agent': 'omp',
  'agents': {'omp': 'installed', 'claude': 'installed'},
  'opensIn': 'kitty',
};

LiveItem _item(int order, ItemKind kind, {String text = '', String tool = '', String title = '', String output = ''}) =>
    LiveItem(
      id: 'it$order',
      kind: kind,
      text: text,
      tool: tool,
      title: title,
      output: output,
      status: ToolStatus.ok,
      order: order,
      seq: order,
    );

/// Each session's conversation, oldest first.
Map<String, List<LiveItem>> demoTranscripts() => {
  'kitty-1/3': [
    _item(
      1,
      ItemKind.user,
      text:
          'Add GET /plants/:id/moisture: the last 24 hours of soil readings, newest first. '
          'Reuse the sensor repo, and add tests.',
    ),
    _item(2, ItemKind.assistant, text: 'Let me look at how the readings are stored first.'),
    _item(3, ItemKind.tool, tool: 'read', title: 'src/sensors/repo.ts'),
    _item(4, ItemKind.tool, tool: 'read', title: 'src/routes/plants.ts'),
    _item(5, ItemKind.tool, tool: 'edit', title: 'src/routes/plants.ts'),
    _item(
      6,
      ItemKind.tool,
      tool: 'bash',
      title: 'npm test -- moisture',
      output:
          ' PASS  test/moisture.test.ts\n'
          '  ✓ last 24 h, newest first (18 ms)\n'
          '  ✓ 404 for an unknown plant (4 ms)\n'
          '\n'
          'Tests:  2 passed, 2 total',
    ),
    _item(
      7,
      ItemKind.assistant,
      text:
          'Done. `GET /plants/:id/moisture` now returns the last 24 h of readings:\n\n'
          '- `SensorRepo.readingsSince()` runs the query, on the `(plant_id, taken_at)` index\n'
          '- an unknown plant gets a **404**\n'
          '- `test/moisture.test.ts` covers both\n\n'
          'Want a `?hours=` parameter as well?',
    ),
  ],
  'wezterm-2': [
    _item(
      1,
      ItemKind.user,
      text: 'The pricing table overflows on phones. Stack the plans under 640 px and keep the Pro column highlighted.',
    ),
    _item(2, ItemKind.tool, tool: 'Read', title: 'src/components/Pricing.tsx'),
    _item(3, ItemKind.tool, tool: 'Edit', title: 'src/components/Pricing.tsx'),
    _item(
      4,
      ItemKind.assistant,
      text: 'The plans now stack below 640 px, Pro first and still highlighted. I want to build the site to check it.',
    ),
  ],
  'tmux-%4': [
    _item(
      1,
      ItemKind.user,
      text: 'Rate-limit GET /plants/search to 30 requests a minute per API key, with a Retry-After header.',
    ),
    _item(2, ItemKind.tool, tool: 'read', title: 'src/middleware/auth.ts'),
    _item(3, ItemKind.tool, tool: 'write', title: 'src/middleware/rateLimit.ts'),
    _item(4, ItemKind.tool, tool: 'edit', title: 'src/routes/search.ts'),
    _item(5, ItemKind.assistant, text: 'The limiter is in place. Running the integration tests now.'),
  ],
};

/// What each terminal window shows.
List<String> demoScreen(String window) => switch (window) {
  demoScreenOnly => [
    ' Import the 2026 seed list from suppliers.csv',
    '',
    ' I will read the CSV, match each row to a catalog entry and',
    ' add the new varieties with their sowing months.',
    '',
    ' ╭──────────────────────────────────────────────╮',
    r' │ $ python scripts/import_seeds.py suppliers.csv │',
    ' ├─── Output ───────────────────────────────────┤',
    ' │ 412 rows read                                │',
    ' │ 388 matched, 24 new                          │',
    ' ╰──────────────────────────────────────────────╯',
    '',
    ' ⠼ 41s > Opus > garden-api',
    '╰─',
  ],
  'tmux-%2' => [
    '# PocketTerm site',
    '',
    'The marketing site, built with Astro.',
    '',
    '## Develop',
    '',
    '    npm install',
    '    npm run dev',
    '~',
    '~',
    '"README.md" 9L, 112B',
  ],
  _ => [
    'demo@MacBook-Pro garden-api % git status',
    'On branch main',
    "Your branch is up to date with 'origin/main'.",
    '',
    'nothing to commit, working tree clean',
    'demo@MacBook-Pro garden-api % ',
  ],
};

/// The demo's computer: its list (one computer) and its remote, answering
/// the app's messages itself. [dispose] when the demo ends.
class DemoComputer {
  DemoComputer(this._cache) {
    _sendState();
    // As a computer does: its state keeps coming, so it reads as online.
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _sendState());
  }

  final Directory _cache;
  Timer? _timer;
  final Map<String, List<LiveItem>> _transcripts = demoTranscripts();
  final _overrides = <String, Map<String, dynamic>>{
    // Prompts waiting for the run at work to end, to look at, change and move in the queue.
    'tmux-%4': {
      'queue': [
        {'id': 'dq1', 't': 'Add a test for the 429 answer and its Retry-After header.'},
        {
          'id': 'dq2',
          't':
              'Then make the limit configurable per API key, 60 requests a minute by default. Read it from '
              'config/limits.yaml, fall back to the default when a key has no entry, and log once at startup '
              'which keys have a limit of their own. Keep the middleware small: the lookup goes in a function of '
              'its own, so it can be tested without a server running.',
        },
        {'id': 'dq3', 't': 'This trace is from production: is it the same bug?', 'im': 1},
        {
          'id': 'dq4',
          't': 'Update the limits section of the docs.',
          'f': ['limits.md'],
        },
      ],
    },
  };
  int _queued = 4;

  /// Never asked anything: the list and the remote are fed here.
  static final _nowhere = PocketTermServerClient(
    const Backend(url: 'http://localhost:1'),
    tokens: MemoryDeviceTokens(),
  );

  late final Desktops desktops = Desktops(
    _nowhere,
    cached: [Desktop(id: demoDesktopId, name: demoDesktopName, platform: 'macos', seenAt: DateTime.now())],
    saved: demoDesktopId,
  );

  late final TerminalRemote remote = TerminalRemote(
    _nowhere,
    _cache,
    desktopId: demoDesktopId,
    key: ChannelKey(List.filled(32, 7)),
    from: 'demo-phone',
    send: (event, payload) => scheduleMicrotask(() => _receive(event, payload)),
    // Images go nowhere either.
    upload: (_, _) async {},
  );

  void _sendState() => remote.handle('state', demoState(overrides: _overrides));

  void _sendItems(String session) {
    final items = _transcripts[session];
    if (items == null) return;
    remote.handle('items', {
      'to': remote.from,
      'session': session,
      'epoch': 'e1',
      'seq': items.length,
      'reset': true,
      'last': true,
      'older': false,
      'items': [for (final i in items) i.toJson()],
    });
  }

  void _receive(String event, Map<String, dynamic> p) {
    if (_timer == null) return;
    switch (event) {
      case 'hello':
        _sendState();
      case 'sync' when p['session'] is String:
        _sendItems(p['session'] as String);
      case 'sync' when p['window'] is String:
        final window = p['window'] as String;
        remote.handle('screen', {'window': window, 'v': 1, 'lines': demoScreen(window)});
      case 'run':
        remote.handle('ran', {'id': p['id'], ..._run(p)});
    }
  }

  /// A conversation goes on: [items] added to [session], its summary [summary].
  void _add(String session, List<(ItemKind, String)> items, Map<String, dynamic> summary) {
    final list = _transcripts[session] ??= [];
    for (final (kind, text) in items) {
      list.add(_item(list.length + 1, kind, text: text));
    }
    _overrides[session] = {
      ...?_overrides[session],
      ...summary,
      'seq': list.length,
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    _sendState();
    _sendItems(session);
  }

  /// What the computer answers to a `run`: nothing is done, the conversation
  /// just goes on as if.
  Map<String, dynamic> _run(Map<String, dynamic> p) {
    final session = p['session'] as String?;
    switch (p['op']) {
      case 'prompt' when session != null && p['deliver'] == 'followUp' && _busy(session):
        final id = 'dq${++_queued}';
        _setQueue(session, [
          ..._queue(session),
          {'id': id, 't': p['text'] as String? ?? ''},
        ]);
        return {'queued': id};
      case 'queue' when session != null:
        return _changeQueue(session, p);
      case 'prompt' when session != null:
        _add(
          session,
          [
            (ItemKind.user, p['text'] as String? ?? ''),
            (
              ItemKind.assistant,
              "This is the demo: there's no computer behind it, so nothing ran. Scan your computer's code to send "
                  'prompts for real.',
            ),
          ],
          {'busy': false},
        );
        return {};
      case 'answer' when session != null:
        final approved = p['approve'] == true;
        _add(
          session,
          [
            (
              ItemKind.assistant,
              approved
                  ? 'Built in 6.2 s. The pricing table stacks on small screens and the Pro plan stays highlighted.'
                  : "Okay, I won't build it. The change is in src/components/Pricing.tsx when you want to check it.",
            ),
          ],
          {'ask': null, 'busy': false},
        );
        return {};
      case 'probe':
        return {'busy': p['window'] == demoScreenOnly};
      case 'older':
        return {};
      default:
        return {'error': demoNoComputer};
    }
  }

  bool _busy(String session) =>
      _sessions(DateTime.now(), _overrides).any((s) => s['key'] == session && s['busy'] == true);

  List<Map<String, dynamic>> _queue(String session) => [
    for (final q in _overrides[session]?['queue'] as List? ?? const [])
      Map<String, dynamic>.of(q as Map<String, dynamic>),
  ];

  void _setQueue(String session, List<Map<String, dynamic>> queue, {bool? paused}) {
    _overrides[session] = {
      ...?_overrides[session],
      'queue': queue,
      'paused': queue.isNotEmpty && (paused ?? _overrides[session]?['paused'] == true),
    };
    _sendState();
  }

  /// The phone's change to [session]'s queue, as the computer makes it (LiveHub in apps/pocketterm-desktop).
  Map<String, dynamic> _changeQueue(String session, Map<String, dynamic> p) {
    final queue = _queue(session);
    final at = queue.indexWhere((q) => q['id'] == p['item']);
    final what = p['do'];
    if (at < 0 && what != 'pause' && what != 'resume') return {'error': 'That prompt has gone to the agent already.'};
    switch (what) {
      case 'edit':
        queue[at]['t'] = p['text'] as String? ?? '';
      case 'remove':
        queue.removeAt(at);
      case 'move':
        final q = queue.removeAt(at);
        queue.insert(((p['to'] as num?)?.toInt() ?? 0).clamp(0, queue.length), q);
      case 'send':
        final q = queue.removeAt(at);
        _setQueue(session, queue);
        _add(session, [(ItemKind.user, q['t'] as String? ?? '')], {});
        return {};
      case 'pause' || 'resume':
        _setQueue(session, queue, paused: what == 'pause');
        return {};
    }
    _setQueue(session, queue);
    return {};
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    remote.dispose();
    desktops.dispose();
    try {
      _cache.deleteSync(recursive: true);
    } on Object catch (e) {
      debugPrint('PocketTerm: demo cache: $e');
    }
  }
}
