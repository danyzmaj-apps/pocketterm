/// The coding agents whose sessions PocketTerm brings to the phone (lib/live.dart):
/// what a new session from the phone starts, how notifications and the phone
/// name a session, and how its dialogs are answered.
enum Agent {
  omp('omp'),
  claude('Claude');

  const Agent(this.label);

  /// How the phone and notifications name it: "Claude finished".
  final String label;

  /// What a shell starts it with, which is also the program the terminal reports.
  String get command => name;

  /// [command] in an omp [profile] (`omp --profile=personal`), as typed; '' is the default profile,
  /// and Claude Code has none.
  String commandIn(String profile) => this == omp && profile.isNotEmpty ? '$command --profile=$profile' : command;

  /// [label] with an omp [profile] that isn't the default: "omp · personal".
  String labelIn(String profile) => this == omp && profile.isNotEmpty ? '$label · $profile' : label;

  /// The command that restarts it on the conversation it had (`omp -c`), for text: it never
  /// breaks across lines (a no-break space, and a word joiner after the hyphen) yet copies as typed.
  String get resume => resumeIn('');

  /// [resume] in an omp [profile] (`omp --profile=personal -c`), with the same no-break characters.
  String resumeIn(String profile) => this == omp && profile.isNotEmpty
      ? '$command\u00A0-\u2060-\u2060profile=$profile\u00A0-\u2060c'
      : '$command\u00A0-\u2060c';

  /// What a session opened before PocketTerm was installed needs to load it, for text:
  /// Claude Code reloads its plugins in place, omp restarts on the same conversation ([resume]).
  String get pickUp => pickUpIn('');

  /// [pickUp] for a session in an omp [profile].
  String pickUpIn(String profile) => switch (this) {
    omp => resumeIn(profile),
    claude => '/reload-plugins',
  };

  /// A prompt sent while it works steers the run (omp); Claude Code queues it
  /// until the run ends.
  bool get steers => this == omp;

  /// [name] as it travels; omp for anything else (an older peer sends none).
  static Agent parse(Object? name) => values.asNameMap()[name] ?? omp;

  /// The agent a terminal window's foreground [program] is, if it is one.
  static Agent? ofProgram(String program) => values.asNameMap()[program];

  /// The session a terminal [title] this agent set names: omp sets
  /// `π > <session name>` (`>` idle; `:` or a spinner frame working, `!`
  /// asking; `π: ` with its title spinner off), the name being its folder's
  /// until the session has one. Null for a title it didn't set, and for
  /// Claude Code, whose title names nothing its sessions report.
  String? sessionOfTitle(String title) => switch (this) {
    omp => RegExp(r'^π(?:: | \S )(.+)$').firstMatch(title)?[1]?.trim(),
    claude => null,
  };
}

/// Whether [name] is a name omp takes for a profile (`omp --profile <name>`).
bool isOmpProfile(String name) => RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(name) && !name.endsWith('.');

/// The omp profile a command line [args] runs in, from its `--profile=<name>` or `--profile <name>`;
/// '' for none, and for a name omp wouldn't take.
String ompProfileOfArgs(String args) {
  final words = args.split(RegExp(r'\s+'));
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    final name = w.startsWith('--profile=')
        ? w.substring('--profile='.length)
        : w == '--profile' && i + 1 < words.length
        ? words[i + 1]
        : null;
    if (name != null) return isOmpProfile(name) ? name : '';
  }
  return '';
}

/// Where PocketTerm stands in a coding agent found on a computer, as the
/// computer tells the phone (the state's `agents`, lib/live.dart): its
/// sessions report to PocketTerm only once it's [installed] and they
/// started after that.
enum AgentIntegration {
  /// Installed and the same as the app's copy.
  installed,

  /// Installed, older than the app's copy.
  outdated,

  /// Not installed, or the agent can't take it (Claude Code too old).
  missing,

  /// Installed in Claude Code, which has mods (its plugins' runtime) turned off.
  off;

  /// The state's `agents`: agent name to value; agents or values this side
  /// doesn't know are left out, and an older computer sends none (empty).
  static Map<Agent, AgentIntegration> parseAll(Object? json) => {
    if (json is Map)
      for (final MapEntry(:key, :value) in json.entries)
        if ((Agent.values.asNameMap()[key], values.asNameMap()[value]) case (final a?, final i?)) a: i,
  };

  static Map<String, String> toJsonAll(Map<Agent, AgentIntegration> agents) => {
    for (final MapEntry(:key, :value) in agents.entries) key.name: value.name,
  };
}
