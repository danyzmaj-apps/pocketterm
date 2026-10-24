part of '../setup_page.dart';

final Uri _supabaseTokens = Uri.parse('https://supabase.com/dashboard/account/tokens');

/// What the Supabase branch talks to: the Management API with the pasted
/// access token, and the setup of one project. Tests pass their own.
class SupabaseTools {
  const SupabaseTools();

  SupabaseAdmin admin(String token) => SupabaseAdmin(token);

  SupabaseSetup setup(SupabaseAdmin admin, String ref) => SupabaseSetup(admin: admin, ref: ref);
}

/// The regions a new project can go to, nearest-sounding names for people.
const supabaseRegions = {
  'us-east-1': 'US East (N. Virginia)',
  'us-west-1': 'US West (N. California)',
  'ca-central-1': 'Canada (Central)',
  'sa-east-1': 'South America (São Paulo)',
  'eu-central-1': 'Europe (Frankfurt)',
  'eu-west-2': 'Europe (London)',
  'ap-south-1': 'Asia Pacific (Mumbai)',
  'ap-southeast-1': 'Asia Pacific (Singapore)',
  'ap-northeast-1': 'Asia Pacific (Tokyo)',
};

/// The three options side by side (the first-run setup's choice).
class OptionsTable extends StatelessWidget {
  const OptionsTable({super.key});

  static const _rows = [
    ('', 'On this computer', 'On my own server', 'Supabase'),
    ('Who runs the server', 'This computer (built in)', 'You, on a VPS you rent', 'Supabase, in a region you pick'),
    ('Who holds the metadata', 'Only you', 'You and your VPS host', 'Supabase'),
    ('Reached through', 'Tailscale', 'Your domain (HTTPS)', 'supabase.co'),
    ('Cost', 'Free', 'A VPS', 'Free plan (pauses after a week unused)'),
    ('This computer must be awake', 'Yes', 'Yes (your sessions run on it)', 'Yes (your sessions run on it)'),
    ('Contents end-to-end encrypted', 'Yes', 'Yes', 'Yes'),
  ];

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 10,
    children: [
      Table(
        key: const ValueKey('compare-table'),
        columnWidths: const {0: FlexColumnWidth(1.25)},
        border: const TableBorder(horizontalInside: BorderSide(color: C.line2)),
        children: [
          for (final (i, r) in _rows.indexed)
            TableRow(
              children: [
                for (final cell in [r.$1, r.$2, r.$3, r.$4])
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 5, 8, 5),
                    child: Text(
                      cell,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: i == 0 || cell == r.$1 ? C.text : C.dim,
                        fontWeight: i == 0 ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
      const Text(
        'Your sessions, images, files and notification text are end-to-end encrypted in all three: whoever runs '
        'the server passes them along but can’t read them. Your sessions always run on this computer, so it has to '
        'be awake with every option.',
      ),
    ],
  );
}

enum _Stage { choose, paste, token, project, progress }

/// Supabase: paste the setup link of a computer already on a project, or
/// set a project up. Setting up asks for a personal access token after
/// saying what it covers and what Supabase holds, then a project (a new one
/// in the picked organization and region, or the one PocketTerm is already
/// on there), then runs [SupabaseSetup] step by step and signs this computer
/// in with the link it makes. The token lives only in this screen.
class SupabaseSetupView extends StatefulWidget {
  const SupabaseSetupView({
    required this.app,
    required this.onBack,
    this.checks = const ServerChecks(),
    this.tools = const SupabaseTools(),
    super.key,
  });
  final AppController app;
  final VoidCallback onBack;
  final ServerChecks checks;
  final SupabaseTools tools;

  @override
  State<SupabaseSetupView> createState() => _SupabaseSetupViewState();
}

class _SupabaseSetupViewState extends State<SupabaseSetupView> {
  _Stage _stage = _Stage.choose;
  final _token = TextEditingController();
  SupabaseAdmin? _admin;

  /// Bumped whenever the work under way no longer counts (Back, a new token).
  int _run = 0;
  bool _busy = false;
  String? _error;

  List<Org>? _orgs;
  String? _org;
  String _region = 'eu-central-1';

  /// The project PocketTerm is on already in [_org], if any.
  Project? _existing;

  /// Being set up; kept so Retry picks up where it stopped.
  String? _ref;
  final Set<SupabaseStep> _done = {};
  SupabaseStep? _current;
  bool _waiting = false;

  @override
  void dispose() {
    _drop();
    _token.dispose();
    super.dispose();
  }

  /// Forgets the token and the work done with it.
  void _drop() {
    _run++;
    _admin?.close();
    _admin = null;
    _token.clear();
    _busy = false;
    _error = null;
    _orgs = null;
    _org = null;
    _existing = null;
    _ref = null;
    _done.clear();
    _current = null;
    _waiting = false;
  }

  void _back() {
    if (_stage == _Stage.choose) return widget.onBack();
    setState(() {
      _drop();
      _stage = _Stage.choose;
    });
  }

  String _why(Object e) => e is AdminException ? e.message : 'Something went wrong: $e';

  Future<void> _continue() async {
    final token = _token.text.trim();
    if (!token.startsWith('sbp_')) {
      return setState(() => _error = 'That isn’t a Supabase access token. It starts with sbp_.');
    }
    final run = ++_run;
    _admin?.close();
    final admin = _admin = widget.tools.admin(token);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final orgs = await admin.organizations();
      if (run != _run || !mounted) return;
      if (orgs.isEmpty) throw const AdminException('This Supabase account has no organization. Create one first.');
      setState(() {
        _orgs = orgs;
        _stage = _Stage.project;
        _busy = false;
      });
      if (orgs.length == 1) await _pickOrg(orgs.single.slug);
    } on Object catch (e) {
      if (run != _run || !mounted) return;
      setState(() {
        _busy = false;
        _error = _why(e);
      });
    }
  }

  /// Picks [slug] and looks for a project PocketTerm is on there already
  /// (best effort: one that can't be asked counts as not).
  Future<void> _pickOrg(String slug) async {
    final run = ++_run;
    final admin = _admin!;
    setState(() {
      _org = slug;
      _existing = null;
      _busy = true;
      _error = null;
    });
    Project? found;
    try {
      for (final p in await admin.projects()) {
        if (p.org != slug || p.status != 'ACTIVE_HEALTHY') continue;
        try {
          if (await widget.tools.setup(admin, p.ref).hasPocketTerm()) {
            found = p;
            break;
          }
        } on Object catch (e) {
          debugPrint('PocketTerm: looking at Supabase project ${p.ref} failed: $e');
        }
      }
    } on Object catch (e) {
      debugPrint('PocketTerm: listing Supabase projects failed: $e');
    }
    if (run != _run || !mounted) return;
    setState(() {
      _existing = found;
      _busy = false;
    });
  }

  /// 32 random letters and digits: the new project's database password,
  /// which PocketTerm never needs again.
  static String _password() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rng = Random.secure();
    return String.fromCharCodes([for (var i = 0; i < 32; i++) chars.codeUnitAt(rng.nextInt(chars.length))]);
  }

  Future<void> _create() async {
    final run = ++_run;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final project = await _admin!.createProject(
        org: _org!,
        name: 'PocketTerm',
        region: _region,
        dbPassword: _password(),
      );
      if (run != _run || !mounted) return;
      _ref = project.ref;
      await _setUp();
    } on Object catch (e) {
      if (run != _run || !mounted) return;
      setState(() {
        _busy = false;
        _error = _why(e);
      });
    }
  }

  Future<void> _update() async {
    _ref = _existing!.ref;
    await _setUp();
  }

  /// Runs the setup on [_ref] from where it stopped, then signs in.
  Future<void> _setUp() async {
    final run = ++_run;
    setState(() {
      _stage = _Stage.progress;
      _busy = true;
      _error = null;
      _waiting = false;
      // The step that failed runs again; it isn't done.
      _current = null;
    });
    try {
      final link = await widget.tools
          .setup(_admin!, _ref!)
          .run(
            done: {..._done},
            onStep: (step) {
              if (run != _run || !mounted) return;
              setState(() {
                if (_current case final c?) _done.add(c);
                _current = step;
                _waiting = false;
              });
            },
            onWait: () {
              if (run == _run && mounted) setState(() => _waiting = true);
            },
          );
      if (!mounted || run != _run) return;
      final app = widget.app;
      await app.connectLink(link);
      if (app.user != null) {
        // Signed in: the window moves on; the token and the admin go now.
        if (mounted) _drop();
        return;
      }
      final why = app.authError ?? 'The setup link didn’t sign this computer in.';
      if (app.backend != null) await app.disconnect();
      throw AdminException(why);
    } on Object catch (e) {
      if (!mounted || run != _run) return;
      setState(() {
        _busy = false;
        _waiting = false;
        _error = _why(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: switch (_stage) {
      _Stage.choose => _choose(),
      _Stage.paste => _paste(),
      _Stage.token => _tokenScreen(),
      _Stage.project => _projectScreen(),
      _Stage.progress => _progress(),
    },
  );

  Widget _option(String key, IconData icon, String title, String text, _Stage next) => Hoverable(
    key: ValueKey(key),
    onTap: () => setState(() => _stage = next),
    builder: (h) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: h ? const Color(0xFF23252E) : C.field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: h ? C.accent : C.line2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 26, color: C.accent),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                Text(text, style: const TextStyle(fontSize: 12.5, color: C.dim, height: 1.45)),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Icon(Icons.chevron_right, size: 20, color: C.dim2),
          ),
        ],
      ),
    ),
  );

  List<Widget> _choose() => [
    _header('Supabase', 'Is PocketTerm already on a Supabase project of yours?', _back),
    _option(
      'supabase-paste',
      Icons.link,
      'Paste a setup link',
      'Another computer of yours already uses it: open Settings, Account, Add a computer… there and paste its '
          'link here.',
      _Stage.paste,
    ),
    const SizedBox(height: 12),
    _option(
      'supabase-new',
      Icons.add_circle_outline,
      'Set up a project',
      'PocketTerm makes a free project in your Supabase account and sets it up. It takes a few minutes.',
      _Stage.token,
    ),
  ];

  List<Widget> _paste() => [
    _header(
      'Paste a setup link',
      'On a computer already signed in to your Supabase project, open Settings, Account, Add a computer… and copy '
          'the link it shows.',
      _back,
    ),
    SetupLinkForm(app: widget.app, checks: widget.checks),
  ];

  Widget _para(String title, String text) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 4,
    children: [
      Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      Text(text, style: const TextStyle(fontSize: 12.5, color: C.dim, height: 1.45)),
    ],
  );

  Widget _errorText() => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(
      _error!,
      key: const ValueKey('supabase-error'),
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 12, color: _errorColor, height: 1.4),
    ),
  );

  Widget _button(String key, String label, VoidCallback? onPressed) => FilledButton(
    key: ValueKey(key),
    onPressed: _busy ? null : onPressed,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: _busy
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : Text(label),
    ),
  );

  List<Widget> _tokenScreen() => [
    _header(
      'Set up a Supabase project',
      'PocketTerm makes a free project in your Supabase account and puts its server there. First, what that means.',
      _back,
    ),
    Column(
      key: const ValueKey('supabase-security'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 14,
      children: [
        _para(
          'What stays private',
          'Your sessions, images, files and notification text stay end-to-end encrypted, exactly as with the other '
              'options. The project only passes them along, sealed.',
        ),
        _para(
          'What Supabase holds',
          'Supabase, in the region you pick, holds what any PocketTerm server holds: your list of devices (names, '
              'platforms, when they were added and last seen), your computers’ names, your phones’ push tokens, '
              'pairing codes for 10 minutes, and when messages and pushes go through. Supabase also sees the IP '
              'addresses your devices connect from.',
        ),
        _para(
          'Signing out a device',
          'A phone or computer you sign out hears it at once and is refused at its next connection. At most its '
              'live connection lasts until its 10-minute token runs out, and what it gets stays sealed.',
        ),
        _para(
          'Free projects pause',
          'Supabase pauses a free project after about a week without use. Restore it at supabase.com/dashboard. '
              'The free plan allows 2 active projects per account.',
        ),
        _para(
          'Your access token',
          'PocketTerm needs a personal access token to make and set up the project. It covers your whole Supabase '
              'organization, every project in it. PocketTerm uses it only during this setup and never stores it. '
              'Best: give PocketTerm a Supabase organization of its own, and delete the token once this is done.',
        ),
      ],
    ),
    const SizedBox(height: 16),
    Row(
      children: [
        const Expanded(
          child: Text(
            'Create a token at supabase.com/dashboard/account/tokens, then paste it here.',
            style: TextStyle(fontSize: 12.5, color: C.dim, height: 1.45),
          ),
        ),
        TextButton(
          key: const ValueKey('supabase-open-tokens'),
          onPressed: () => openLink(_supabaseTokens),
          style: TextButton.styleFrom(foregroundColor: C.accent),
          child: const Text('Create a token'),
        ),
      ],
    ),
    const SizedBox(height: 8),
    TextField(
      key: const ValueKey('supabase-token'),
      controller: _token,
      enabled: !_busy,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      decoration: setupField('sbp_…'),
      onSubmitted: (_) => unawaited(_continue()),
    ),
    const SizedBox(height: 14),
    _button('supabase-continue', 'Continue', () => unawaited(_continue())),
    if (_error != null) _errorText(),
  ];

  Widget _dropdown<T>(String key, T? value, Map<T, String> items, ValueChanged<T> onChanged) => Container(
    padding: const EdgeInsets.only(left: 12, right: 6),
    decoration: BoxDecoration(
      color: C.field,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: C.line2),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        key: ValueKey(key),
        value: value,
        isExpanded: true,
        focusColor: Colors.transparent,
        dropdownColor: C.bar,
        borderRadius: BorderRadius.circular(8),
        hint: const Text('Choose…', style: TextStyle(color: C.dim2)),
        style: DefaultTextStyle.of(context).style.copyWith(fontSize: 13, color: C.text),
        items: [
          for (final MapEntry(:key, value: label) in items.entries) DropdownMenuItem(value: key, child: Text(label)),
        ],
        onChanged: _busy
            ? null
            : (v) {
                if (v != null) onChanged(v);
              },
      ),
    ),
  );

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: const TextStyle(fontSize: 12.5, color: C.dim)),
  );

  List<Widget> _projectScreen() {
    final existing = _existing;
    return [
      _header('Choose where it goes', 'PocketTerm makes a new project called PocketTerm. It touches no other.', _back),
      _label('Organization'),
      _dropdown<String>('supabase-org', _org, {
        for (final o in _orgs!) o.slug: o.plan.isEmpty ? o.name : '${o.name} (${o.plan} plan)',
      }, (slug) => unawaited(_pickOrg(slug))),
      const SizedBox(height: 14),
      if (existing != null) ...[
        _notice(
          'PocketTerm is already on ${existing.name} in this organization. Update that project instead of making '
          'another: every phone and computer on it stays signed in.',
          key: const ValueKey('supabase-existing'),
        ),
        const SizedBox(height: 14),
        _button('supabase-update', 'Update that project', () => unawaited(_update())),
      ] else ...[
        _label('Region'),
        _dropdown<String>('supabase-region', _region, supabaseRegions, (r) => setState(() => _region = r)),
        const SizedBox(height: 6),
        const Text(
          'Pick one near you: your device list is kept there.',
          style: TextStyle(fontSize: 12, color: C.dim2, height: 1.4),
        ),
        const SizedBox(height: 14),
        _button('supabase-create', 'Create the project', _org == null ? null : () => unawaited(_create())),
      ],
      if (_error != null) _errorText(),
    ];
  }

  List<Widget> _progress() => [
    _header('Setting up your project', 'This takes a few minutes. Keep this window open.', _back),
    for (final step in SupabaseStep.values)
      SetupCheck(
        key: ValueKey('supabase-step-${step.name}'),
        title: step.label,
        state: _done.contains(step)
            ? CheckState.done
            : step == _current
            ? (_error == null ? CheckState.looking : CheckState.now)
            : CheckState.later,
      ),
    if (_waiting) ...[
      const SizedBox(height: 12),
      _notice(
        'Supabase lets a project change its signing key only every few minutes. Waiting…',
        icon: Icons.schedule,
        key: const ValueKey('supabase-wait'),
      ),
    ],
    if (_error != null) ...[
      _errorText(),
      const SizedBox(height: 14),
      FilledButton(
        key: const ValueKey('supabase-retry'),
        onPressed: () => unawaited(_setUp()),
        child: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Retry')),
      ),
    ],
  ];
}
