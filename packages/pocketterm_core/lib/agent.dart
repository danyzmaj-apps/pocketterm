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

  /// The command that restarts it on the conversation it had (`omp -c`), for text: it never
  /// breaks across lines (a no-break space, and a word joiner after the hyphen) yet copies as typed.
  String get resume => '$command\u00A0-\u2060c';

  /// A prompt sent while it works steers the run (omp); Claude Code queues it
  /// until the run ends.
  bool get steers => this == omp;

  /// [name] as it travels; omp for anything else (an older peer sends none).
  static Agent parse(Object? name) => values.asNameMap()[name] ?? omp;

  /// The agent a terminal window's foreground [program] is, if it is one.
  static Agent? ofProgram(String program) => values.asNameMap()[program];
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
