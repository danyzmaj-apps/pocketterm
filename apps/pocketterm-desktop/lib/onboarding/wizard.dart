import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/logo.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/onboarding/flow.dart';
import 'package:pocketterm_desktop/onboarding/provision.dart';
import 'package:pocketterm_desktop/wezterm_setup.dart';
import 'package:url_launcher/url_launcher.dart';

const _tokensUrl = 'https://supabase.com/dashboard/account/tokens';
const _homepage = 'https://github.com/danyzmaj-apps/pocketterm';

void _open(String url) => unawaited(launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication));

/// The guided setup: one step at a time, each with what to do, a button that
/// opens the right page, and the field to paste into. On Windows, the
/// server's minute of setting up also gets WezTerm onto the PC.
class SetupWizard extends StatefulWidget {
  const SetupWizard({required this.flow, required this.onConnect, required this.onExisting, this.wezterm, super.key});
  final SetupFlow flow;

  /// Connects the app to the finished server (the session's connect).
  final Future<void> Function(Backend backend) onConnect;

  /// "I already have a server": the plain connect form.
  final VoidCallback onExisting;

  /// Windows: WezTerm, which PocketTerm needs there; null elsewhere.
  final WezTermSetup? wezterm;

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  SetupFlow get flow => widget.flow;
  final _token = TextEditingController();
  final _name = TextEditingController(text: 'pocketterm');
  final _githubId = TextEditingController();
  final _githubSecret = TextEditingController();

  @override
  void dispose() {
    for (final c in [_token, _name, _githubId, _githubSecret]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([flow, ?widget.wezterm]),
    // A tap outside a field takes the focus off it.
    builder: (context, _) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: Center(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (flow.step != WizardStep.welcome) _progress(),
                ...switch (flow.step) {
                  WizardStep.welcome => _welcome(),
                  WizardStep.token => _tokenStep(),
                  WizardStep.project => _projectStep(),
                  WizardStep.github => _githubStep(),
                  WizardStep.setup => _setupStep(),
                },
                if (flow.error case final e?) ...[
                  const SizedBox(height: 14),
                  Text(e, style: const TextStyle(fontSize: 12.5, height: 1.4, color: Color(0xFFFCA5A5))),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );

  // ---------------------------------------------------------------- pieces

  Widget _progress() {
    const steps = [WizardStep.token, WizardStep.project, WizardStep.github, WizardStep.setup];
    final at = steps.indexOf(flow.step);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Row(
        children: [
          for (var i = 0; i < steps.length; i++)
            Expanded(
              child: Container(
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(color: i <= at ? C.accent : C.line2, borderRadius: BorderRadius.circular(2)),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _header(String title, String body) => [
    Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
    const SizedBox(height: 8),
    Text(body, style: const TextStyle(color: C.dim, height: 1.45)),
    const SizedBox(height: 18),
  ];

  Widget _primary(String label, VoidCallback? onPressed) => FilledButton(
    onPressed: flow.busy ? null : onPressed,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: flow.busy
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : Text(label),
    ),
  );

  Widget _link(String label, String url) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      onPressed: () => _open(url),
      icon: const Icon(Icons.open_in_new, size: 15),
      label: Text(label),
      style: TextButton.styleFrom(padding: EdgeInsets.zero),
    ),
  );

  /// Works while a new project starts too: the wizard stops waiting, and the
  /// project stays picked for next time.
  Widget _back(WizardStep to) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton(
      onPressed: flow.busy && flow.waiting == null ? null : () => flow.go(to),
      style: TextButton.styleFrom(foregroundColor: C.dim2, padding: EdgeInsets.zero),
      child: const Text('← Back'),
    ),
  );

  /// A value to put into another site's form, with a copy button.
  Widget _copyRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: C.field,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: C.line2),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 11, color: C.dim)),
                const SizedBox(height: 2),
                SelectableText(value, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy',
            iconSize: 16,
            color: C.dim,
            icon: const Icon(Icons.copy_outlined),
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: value)));
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$label copied')));
            },
          ),
        ],
      ),
    ),
  );

  // ---------------------------------------------------------------- steps

  List<Widget> _welcome() => [
    const Center(child: PocketTermLogo(size: 56)),
    const SizedBox(height: 14),
    const Text(
      'Welcome to PocketTerm',
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
    ),
    const SizedBox(height: 10),
    const Text(
      "PocketTerm puts this computer's coding sessions on your phone. They go through your own free "
      'Supabase server, so nobody else holds your data. This sets one up for you in about five minutes: '
      'you create two free accounts and paste a few keys, the app does the rest.',
      textAlign: TextAlign.center,
      style: TextStyle(color: C.dim, height: 1.5),
    ),
    const SizedBox(height: 24),
    _primary('Set up my server', () => flow.go(WizardStep.token)),
    const SizedBox(height: 10),
    TextButton(onPressed: widget.onExisting, child: const Text('I already have one: connect it')),
  ];

  List<Widget> _tokenStep() => [
    ..._header(
      '1. Your Supabase account',
      'Supabase hosts your server (free). Sign up or log in, then create an access token so the '
          'app can set the server up for you. Name it "PocketTerm setup"; you can delete it once you are done.',
    ),
    _link('Open Supabase access tokens', _tokensUrl),
    const SizedBox(height: 8),
    TextField(
      controller: _token,
      obscureText: true,
      autocorrect: false,
      enabled: !flow.busy,
      decoration: setupField('Access token (sbp_…)'),
      onSubmitted: (_) => unawaited(flow.submitToken(_token.text)),
    ),
    const SizedBox(height: 6),
    const Text(
      'The token stays in this window only; the app never saves it.',
      style: TextStyle(fontSize: 11.5, color: C.dim2),
    ),
    const SizedBox(height: 16),
    _primary('Continue', () => unawaited(flow.submitToken(_token.text))),
    _back(WizardStep.welcome),
  ];

  List<Widget> _projectStep() {
    final usable = flow.usableProjects;
    return [
      ..._header(
        '2. Your server',
        'A Supabase project is the server. Create a new one for PocketTerm, or use one you already have.',
      ),
      _choice(
        selected: flow.createNew,
        title: 'Create a new project',
        onTap: () => flow.update(() => flow.createNew = true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              enabled: !flow.busy,
              decoration: setupField('Name'),
              onChanged: (v) => flow.newName = v,
            ),
            const SizedBox(height: 8),
            _dropdown(
              value: flow.region,
              items: {for (final (code, city) in regions) code: '$city ($code)'},
              onChanged: (v) => flow.update(() => flow.region = v),
            ),
            if (flow.orgs.length > 1) ...[
              const SizedBox(height: 8),
              _dropdown(
                value: flow.org!,
                items: {for (final o in flow.orgs) o.slug: o.name},
                onChanged: (v) => flow.update(() => flow.org = v),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 8),
      _choice(
        selected: !flow.createNew,
        enabled: usable.isNotEmpty,
        title: usable.isEmpty ? 'Use an existing project (none running)' : 'Use an existing project',
        onTap: () => flow.update(() {
          flow.createNew = false;
          flow.existingRef ??= usable.firstOrNull?.ref;
        }),
        child: usable.isEmpty
            ? null
            : _dropdown(
                value: flow.existingRef ?? usable.first.ref,
                items: {for (final p in usable) p.ref: p.status == 'ACTIVE_HEALTHY' ? p.name : '${p.name} (starting)'},
                onChanged: (v) => flow.update(() => flow.existingRef = v),
              ),
      ),
      if (!flow.createNew && flow.caution == null)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'A project of its own is best: PocketTerm makes sign-in private to your account. It looks at this one '
            'first and tells you if something is in the way.',
            style: TextStyle(fontSize: 11.5, color: C.dim2),
          ),
        ),
      if (flow.caution case final c?) ...[
        const SizedBox(height: 14),
        Text(c, style: const TextStyle(fontSize: 12.5, height: 1.4, color: C.warn)),
      ],
      if (flow.waiting case final w?) ...[const SizedBox(height: 14), Text(w, style: const TextStyle(color: C.dim))],
      const SizedBox(height: 16),
      _primary(
        flow.createNew
            ? 'Create project'
            : flow.caution != null
            ? 'Use it anyway'
            : 'Continue',
        () => unawaited(flow.submitProject()),
      ),
      _back(WizardStep.token),
    ];
  }

  List<Widget> _githubStep() => [
    ..._header(
      '3. Sign-in with GitHub',
      'You sign in to your server with GitHub. Register it as a GitHub "OAuth app" (free, a minute): '
          'open the form, fill it in with the values below, then generate a client secret on the next page.',
    ),
    _copyRow('Application name', 'PocketTerm'),
    _copyRow('Homepage URL', _homepage),
    _copyRow('Authorization callback URL', flow.githubCallback),
    _link('Open GitHub: new OAuth app', _githubFormUrl()),
    const SizedBox(height: 8),
    TextField(
      controller: _githubId,
      autocorrect: false,
      enabled: !flow.busy,
      decoration: setupField('Client ID'),
      onChanged: (v) => flow.githubId = v,
    ),
    const SizedBox(height: 8),
    TextField(
      controller: _githubSecret,
      autocorrect: false,
      obscureText: true,
      enabled: !flow.busy,
      decoration: setupField('Client secret ("Generate a new client secret")'),
      onChanged: (v) => flow.githubSecret = v,
      onSubmitted: (_) => unawaited(flow.submitGithub()),
    ),
    const SizedBox(height: 16),
    _primary('Set up my server', () => unawaited(flow.submitGithub())),
    _back(WizardStep.project),
  ];

  String _githubFormUrl() => Uri.https('github.com', '/settings/applications/new', {
    'oauth_application[name]': 'PocketTerm',
    'oauth_application[url]': _homepage,
    'oauth_application[callback_url]': flow.githubCallback,
  }).toString();

  List<Widget> _setupStep() {
    final finished = flow.ready;
    final failed = !finished && flow.error != null && !flow.busy;
    return [
      ..._header(
        finished ? 'Your server is ready' : '4. Setting up your server',
        finished
            ? 'Connect, then sign in with GitHub. The first account to sign in owns this server. '
                  'To add your phone afterwards: Settings → Set up phone, and scan the code.'
            : 'This takes about a minute.',
      ),
      for (final s in ProvisionStep.values)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: flow.done.contains(s) || (finished && s == ProvisionStep.keys)
                    ? const Icon(Icons.check_circle, size: 18, color: C.ok)
                    : flow.current == s && flow.busy
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : flow.current == s && failed
                    ? const Icon(Icons.error_outline, size: 18, color: Color(0xFFFCA5A5))
                    : const Icon(Icons.circle_outlined, size: 18, color: C.dim2),
              ),
              const SizedBox(width: 10),
              Text(s.label),
            ],
          ),
        ),
      if (widget.wezterm case final w?) ...[const SizedBox(height: 18), _weztermCard(w)],
      const SizedBox(height: 18),
      // A failed connect shows its error below, and the button tries again.
      if (finished) ...[_primary('Connect and sign in', () => unawaited(flow.connect(widget.onConnect)))],
      if (failed) ...[_primary('Retry', () => unawaited(flow.setUp())), _back(WizardStep.github)],
    ];
  }

  /// Windows: WezTerm, checked off when it's on the PC, else one button to
  /// install it (its own installer, visible) and the winget line for those
  /// who'd rather type it.
  Widget _weztermCard(WezTermSetup w) => Container(
    key: const ValueKey('wizard-wezterm'),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: C.field,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: C.line2),
    ),
    child: w.installed
        ? const Row(
            children: [
              Icon(Icons.check_circle, size: 18, color: C.ok),
              SizedBox(width: 10),
              Expanded(child: Text('WezTerm is installed: your phone can reach its windows.')),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Your terminal: WezTerm', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text(
                'On Windows, PocketTerm works through WezTerm, a free terminal app. Sessions you start from '
                'your phone open in it, and its windows show on your phone. Windows Terminal and PowerShell '
                "windows don't.",
                style: TextStyle(color: C.dim, height: 1.45, fontSize: 13),
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(
                key: const ValueKey('wizard-wezterm-install'),
                onPressed: w.state == WezTermSetupState.missing ? () => unawaited(w.install()) : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(switch (w.state) {
                    WezTermSetupState.downloading => 'Downloading WezTerm…',
                    WezTermSetupState.installing => 'Finish in WezTerm\u2019s installer',
                    _ => 'Install WezTerm',
                  }),
                ),
              ),
              if (w.state == WezTermSetupState.downloading) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: w.progress, minHeight: 3),
              ],
              if (w.note case final n? when w.state != WezTermSetupState.downloading) ...[
                const SizedBox(height: 8),
                Text(
                  n,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: w.error != null ? const Color(0xFFFCA5A5) : C.dim,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _copyRow('Or type this in PowerShell', WezTermSetup.wingetCommand),
            ],
          ),
  );

  // ---------------------------------------------------------------- inputs

  Widget _choice({
    required bool selected,
    required String title,
    required VoidCallback onTap,
    Widget? child,
    bool enabled = true,
  }) => Opacity(
    opacity: enabled ? 1 : .5,
    child: GestureDetector(
      onTap: enabled && !flow.busy ? onTap : null,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? C.sel : C.field,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? C.accent : C.line2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 16,
                  color: selected ? C.accent : C.dim,
                ),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
              ],
            ),
            if (selected && child != null) ...[const SizedBox(height: 10), child],
          ],
        ),
      ),
    ),
  );

  Widget _dropdown({
    required String value,
    required Map<String, String> items,
    required ValueChanged<String> onChanged,
  }) => DropdownButtonFormField<String>(
    initialValue: value,
    isExpanded: true,
    dropdownColor: C.bar,
    decoration: setupField(''),
    items: [for (final MapEntry(:key, value: label) in items.entries) DropdownMenuItem(value: key, child: Text(label))],
    onChanged: flow.busy ? null : (v) => v == null ? null : onChanged(v),
  );
}
