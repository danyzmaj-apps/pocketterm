package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * The coding agents whose sessions PocketTerm brings to the phone: what a new session from
 * the phone starts, how notifications and the phone name a session, and how its dialogs are answered.
 */
enum class Agent(
    /** How the phone and notifications name it: "Claude finished". */
    val label: String,
) {
    omp("omp"),
    claude("Claude");

    /** What a shell starts it with, which is also the program the terminal reports. */
    val command: String get() = name

    /** [command] in an omp [profile] (`omp --profile=personal`), as typed; '' is the default profile, and Claude Code has none. */
    fun commandIn(profile: String): String = if (this == omp && profile.isNotEmpty()) "$command --profile=$profile" else command

    /** [label] with an omp [profile] that isn't the default: "omp · personal". */
    fun labelIn(profile: String): String = if (this == omp && profile.isNotEmpty()) "$label · $profile" else label

    /**
     * The command that restarts it on the conversation it had (`omp -c`), for text: it never
     * breaks across lines (a no-break space, and a word joiner after the hyphen) yet copies as typed.
     */
    val resume: String get() = resumeIn("")

    /** [resume] in an omp [profile] (`omp --profile=personal -c`), with the same no-break characters. */
    fun resumeIn(profile: String): String = if (this == omp && profile.isNotEmpty()) {
        "$command\u00A0-\u2060-\u2060profile=$profile\u00A0-\u2060c"
    } else {
        "$command\u00A0-\u2060c"
    }

    /**
     * What a session opened before PocketTerm was installed needs to load it, for text:
     * Claude Code reloads its plugins in place, omp restarts on the same conversation ([resume]).
     */
    val pickUp: String get() = pickUpIn("")

    /** [pickUp] for a session in an omp [profile]. */
    fun pickUpIn(profile: String): String = when (this) {
        omp -> resumeIn(profile)
        claude -> "/reload-plugins"
    }

    /** A prompt sent while it works steers the run (omp); Claude Code queues it until the run ends. */
    val steers: Boolean get() = this == omp

    /**
     * The session a terminal [title] this agent set names: omp sets `π > <session name>`
     * (`>` idle; `:` or a spinner frame working, `!` asking; `π: ` with its title spinner off),
     * the name being its folder's until the session has one. Null for a title it didn't set,
     * and for Claude Code, whose title names nothing its sessions report.
     */
    fun sessionOfTitle(title: String): String? = when (this) {
        omp -> OMP_TITLE.find(title)?.groupValues?.get(1)?.trim()
        claude -> null
    }

    companion object {
        private val OMP_TITLE = Regex("""^π(?:: | \S )(.+)$""")

        /** [name] as it travels; omp for anything else (an older peer sends none). */
        fun parse(name: Any?): Agent = entries.firstOrNull { it.name == nameOf(name) } ?: omp

        /** The agent a terminal window's foreground [program] is, if it is one. */
        fun ofProgram(program: String): Agent? = entries.firstOrNull { it.name == program }

        private fun nameOf(v: Any?): String? = when (v) {
            is String -> v
            is JsonElement -> v.str
            else -> null
        }
    }
}

private val OMP_PROFILE = Regex("""^[a-z0-9][a-z0-9._-]{0,63}$""")

/** Whether [name] is a name omp takes for a profile (`omp --profile <name>`). */
fun isOmpProfile(name: String): Boolean = OMP_PROFILE.matches(name) && !name.endsWith(".")

/**
 * The omp profile a command line [args] runs in, from its `--profile=<name>` or `--profile <name>`
 * as omp reads them: the last one before `--`, `default` being none; '' for none, and for a name
 * omp wouldn't take.
 */
fun ompProfileOfArgs(args: String): String {
    val words = args.split(Regex("""\s+"""))
    var found: String? = null
    var i = 0
    while (i < words.size) {
        val w = words[i]
        if (w == "--") break
        if (w.startsWith("--profile=")) {
            found = w.substring("--profile=".length)
        } else if (w == "--profile" && i + 1 < words.size) {
            found = words[++i]
        }
        i++
    }
    val f = found
    return if (f != null && f != "default" && isOmpProfile(f)) f else ""
}

/**
 * Where PocketTerm stands in a coding agent found on a computer, as the computer tells the
 * phone (the state's `agents`): its sessions report to PocketTerm only once it's [installed]
 * and they started after that.
 */
enum class AgentIntegration {
    /** Installed and the same as the app's copy. */
    installed,

    /** Installed, older than the app's copy. */
    outdated,

    /** Not installed, or the agent can't take it (Claude Code too old). */
    missing,

    /** Installed in Claude Code, which has mods (its plugins' runtime) turned off. */
    off;

    companion object {
        /**
         * The state's `agents`: agent name to value; agents or values this side doesn't know
         * are left out, and an older computer sends none (empty).
         */
        fun parseAll(json: JsonElement?): Map<Agent, AgentIntegration> {
            val o = json as? JsonObject ?: return emptyMap()
            val out = linkedMapOf<Agent, AgentIntegration>()
            for ((k, v) in o) {
                val a = Agent.entries.firstOrNull { it.name == k } ?: continue
                val i = entries.firstOrNull { it.name == v.str } ?: continue
                out[a] = i
            }
            return out
        }

        fun toJsonAll(agents: Map<Agent, AgentIntegration>): JsonObject =
            JsonObject(agents.entries.associateTo(linkedMapOf()) { (k, v) -> k.name to kotlinx.serialization.json.JsonPrimitive(v.name) })
    }
}
