package com.danyzmaj.pocketterm.state

import com.danyzmaj.pocketterm.core.ChangeNotifier
import com.danyzmaj.pocketterm.core.PreferenceStore

/** The first-use tips, in the order they show: the switch tour first, then the list's, then the conversation page's. */
enum class Tip(val id: String, val caption: String) {
    switchOpen("switch-open", "This session shows only its screen. Tap it to open."),
    switchButton(
        "switch-button",
        "Turns this into a conversation, with chat, approvals and pushes. " +
            "omp restarts on the same conversation; Claude Code just reloads.",
    ),
    switchDone("switch-done", "Now it’s a conversation. Tap to open it."),
    projectHeading("project-heading", "Tap to fold this project. Long-press for its menu."),
    swipeRow("swipe-row", "Swipe left to end the session or close the window."),
    newSession("new-session", "Start your agent or a shell in any project."),
    slash("slash", "Type / for slash commands."),
    queue("queue", "Off: your prompt steers the agent now. On: it waits until the run ends."),
    follow("follow", "Follow this session in your notifications."),
    openScreen("open-screen", "See the raw terminal screen.");

    /** A step of the switch tour: while it waits on its page and isn't in view, no later tip shows there. */
    val tour: Boolean get() = this == switchOpen || this == switchDone
}

/**
 * Which tips this install has seen, kept in [prefs] (per phone, not per account). None shows until
 * [answered]: a fresh install first asks whether to have them (the tour question on the list). With
 * [startSeen] a fresh install starts answered with every tip seen, so the end-to-end flows aren't held
 * up by them (E2E debug builds only), until Show tips again.
 */
class Tips(private val prefs: PreferenceStore, startSeen: Boolean = false) : ChangeNotifier() {
    private val seen: MutableSet<String> =
        (prefs.getStringList(SEEN_KEY) ?: if (startSeen) Tip.entries.map { it.id } else emptyList()).toMutableSet()

    /** Whether the person said whether they want the tips (or brought them back): until then none shows. */
    var answered: Boolean = startSeen || prefs.getStringList(SEEN_KEY) != null
        private set

    fun seen(tip: Tip): Boolean = tip.id in seen

    /** The first tip of [candidates] (those whose anchors are on screen now) that may show: answered, unseen, in tour order. */
    fun next(candidates: Collection<Tip>): Tip? =
        if (!answered) null else Tip.entries.firstOrNull { it in candidates && it.id !in seen }

    /** The answer to the tour question: with [tour] the tips show from the first, without it they're all seen. */
    fun answer(tour: Boolean) {
        if (tour) return reset()
        answered = true
        seen.addAll(Tip.entries.map { it.id })
        save()
    }

    /** The window a switch to the conversation view just turned into a session: its row gets [Tip.switchDone]. */
    var switchedWindow: String? = null
        private set

    fun switched(window: String) {
        switchedWindow = window
        notifyListeners()
    }

    fun markSeen(tip: Tip) {
        if (!seen.add(tip.id)) return
        save()
    }

    /** Every tip shows again, without asking first. */
    fun reset() {
        answered = true
        seen.clear()
        // Kept empty rather than removed: no list is a fresh install, which asks first ([answered]).
        save()
    }

    private fun save() {
        prefs.setStringList(SEEN_KEY, seen.toList())
        notifyListeners()
    }

    companion object {
        /** The seen ids; kept from the first answer on (empty for Show me), so a missing list is a question not answered. */
        const val SEEN_KEY = "pocketterm_tips_seen"
    }
}
