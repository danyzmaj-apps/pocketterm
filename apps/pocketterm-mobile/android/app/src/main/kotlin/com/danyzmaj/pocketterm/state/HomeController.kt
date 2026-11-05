package com.danyzmaj.pocketterm.state

import com.danyzmaj.pocketterm.core.ChangeNotifier
import com.danyzmaj.pocketterm.core.ChannelKey
import com.danyzmaj.pocketterm.core.Desktops
import com.danyzmaj.pocketterm.core.LiveActivities
import com.danyzmaj.pocketterm.core.Native
import com.danyzmaj.pocketterm.core.NativeEvent
import com.danyzmaj.pocketterm.core.TerminalLink
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.core.splitRoutedKey
import com.danyzmaj.pocketterm.core.timing
import com.danyzmaj.pocketterm.ui.common.serverUnreachable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import kotlin.time.Duration.Companion.seconds

/**
 * What the home screen shows, without the UI: the account's computers ([desktops]) and a
 * [TerminalRemote] for the selected one while this phone has its key ([remote]); the routed sessions
 * a tapped push or followed session's link opens; attaching while the app is in front. One per root
 * (a sign-in, or the demo): a new one comes when that changes, and [dispose] drops this one.
 *
 * Confined to the main thread ([scope]).
 */
class HomeController(
    private val session: MobileSession,
    private val native: Native,
    private val scope: CoroutineScope,
    /** Where remotes keep their caches (the Flutter app's application support folder: filesDir). */
    private val supportDir: File,
    /** The demo's computers and remote, instead of the server's. */
    demoDesktops: Desktops? = null,
    private val demoRemote: TerminalRemote? = null,
) : ChangeNotifier() {
    /** The UI's side: open a session's page, take it away again, say something. Set by the home screen. */
    interface Ui {
        /** Opens session [key] of [remote] (its page shows what this phone has, then fills in). */
        fun openSession(remote: TerminalRemote, key: String)

        /** Whether session [key]'s page is the one in front. */
        fun showingSession(key: String): Boolean

        /** Takes session [key]'s page away, if it's there. */
        fun closeSession(key: String)

        /** Takes every page and sheet over the home screen away (the remote they were on went). */
        fun popToHome()

        /** Whether the home screen is in front (nothing over it). */
        val atHome: Boolean

        fun toast(message: String)
    }

    var ui: Ui? = null

    val demo: Boolean = demoRemote != null

    val desktops: Desktops = demoDesktops ?: session.desktops()

    /**
     * The selected computer's coding sessions and terminal windows, through PocketTerm there; live
     * while the app is in front. Null with no computer, and with a locked one (no key).
     */
    var remote: TerminalRemote? = null
        private set
    private var attached = false
    private var resumed = true

    private val syncListener: () -> Unit = { syncRemote() }
    private val linkListener: () -> Unit = { openLinkedSession() }
    private val onlineListener: () -> Unit = { pushWhenOnline() }
    private val jobs = mutableListOf<Job>()

    init {
        desktops.addListener(syncListener)
        // A computer's key scanned; a followed session's link, also the one that launched the app.
        session.addListener(syncListener)
        session.addListener(linkListener)
        jobs += scope.launch { native.events.collect(::onNative) }
        jobs += scope.launch { session.notices.collect { ui?.toast(it) } }
        // While the list is in front, the computers are fetched this often (and on coming to the front).
        jobs += scope.launch {
            while (true) {
                delay(REFRESH_EVERY)
                refreshIfInFront()
            }
        }
        syncRemote()
    }

    /** The home screen is up: a push tapped or a link opened before it was there comes now. */
    fun started() {
        timing("home")
        scope.launch { openTappedSession() }
        openLinkedSession()
        refreshIfInFront()
    }

    /**
     * One remote, for the selected computer while this phone has its key: another computer selected,
     * or a new key scanned, the old one goes (with any page on it) and a new one comes.
     */
    private fun syncRemote() {
        // A code just scanned: that computer, not the one seen last.
        session.takeScannedComputer()?.let { id ->
            desktops.show(id)
            if (desktops.all.none { it.id == id }) scope.launch { desktops.refresh() }
        }
        val d = desktops.selected
        val key: ChannelKey? = d?.let { session.computerKey(it.id) }
        val old = remote
        if (old != null && old.desktopId == d?.id && old.key == key) {
            old.desktopName = d?.name
            old.desktopSeenAt = d?.seenAt?.toEpochMilli()
            syncFollow(old)
            return advanceRouted()
        }
        var next: TerminalRemote? = null
        if (d != null && key != null) {
            next = demoRemote ?: TerminalRemote(session.server!!, supportDir, desktopId = d.id, key = key, scope = scope)
            next.desktopName = d.name
            next.desktopSeenAt = d.seenAt.toEpochMilli()
            syncFollow(next)
            next.addListener(onlineListener)
        }
        if (old != null) {
            ui?.popToHome()
            dropRemote(old)
        }
        remote = next
        notifyListeners()
        if (next != null && resumed) attach(true)
        advanceRouted()
    }

    /** Following sessions (ongoing notifications) needs push: with it off there's no Follow, and nothing registers. */
    fun syncFollow() {
        remote?.let(::syncFollow)
    }

    private fun syncFollow(t: TerminalRemote) {
        val server = session.server
        val on = !demo && session.pushEnabled == true && server != null
        if (on && t.activities == null) {
            t.activities = LiveActivities(server!!, t, native, scope)
        } else if (!on && t.activities != null) {
            t.activities?.dispose()
            t.activities = null
        }
    }

    private fun dropRemote(t: TerminalRemote) {
        attached = false
        t.removeListener(onlineListener)
        t.activities?.dispose()
        t.activities = null
        if (t !== demoRemote) t.dispose()
    }

    /** The computer's connection is back: a push token the server missed goes again. */
    private fun pushWhenOnline() {
        val t = remote ?: return
        if (t.online && session.pushUnsent && !demo) scope.launch { session.retryPush() }
    }

    private fun attach(on: Boolean) {
        val t = remote ?: return
        if (on == attached || t === demoRemote) return
        attached = on
        if (on) t.attach() else t.detach()
    }

    /** The list of computers, unless a page is over it or the app is away. */
    private fun refreshIfInFront() {
        if (demo || !resumed || ui?.atHome == false) return
        scope.launch { desktops.refresh() }
    }

    /** Asked again now (Retry), not at the next 30-second refresh. */
    fun retryDesktops() {
        session.server?.freshConnections()
        scope.launch { desktops.refresh() }
    }

    /** Why the list of computers didn't come, if it didn't: a server the phone can't reach says what to do. */
    val desktopsError: String?
        get() {
            val e = desktops.error ?: return null
            val b = session.backend
            return if (b != null && e == b.unreachable) serverUnreachable(b) else e
        }

    // ------------------------------------------------------------------ lifecycle

    fun onResume() {
        timing("resumed")
        resumed = true
        // Before anything asks the server: connections from before may have died while away.
        session.server?.freshConnections()
        attach(true)
        refreshIfInFront()
        scope.launch { openTappedSession() }
        // Notifications may have been turned off or on in Settings meanwhile.
        if (!demo) {
            scope.launch {
                session.checkNotifications()
                // A push token the server missed while it was unreachable.
                session.retryPush(force = true)
            }
        }
    }

    fun onPause() {
        timing("paused")
        resumed = false
        attach(false)
    }

    /**
     * From the platform side: a terminal push was tapped, or a followed session has news, or FCM
     * changed this phone's token.
     */
    private fun onNative(e: NativeEvent) {
        when (e.event) {
            // The session comes through takeTappedSession, once, whichever of this and the resume asks first.
            "openTerminal" -> scope.launch { openTappedSession() }
            "activityToken", "activityEnded" -> remote?.activities?.onNative(e.event, e.args)
            "pushToken" -> scope.launch { session.pushTokenChanged() }
        }
    }

    // ------------------------------------------------------------------ routed sessions

    /** A tapped push's or followed session's session, on its way to showing ([openRouted]). */
    private class Routed(val desktop: String, val key: String, val timer: Job) {
        var opened = false
        var remote: TerminalRemote? = null
        var listener: (() -> Unit)? = null
    }

    private var routed: Routed? = null

    private suspend fun openTappedSession() {
        native.takeTappedSession()?.let(::openRouted)
    }

    private fun openLinkedSession() {
        session.takeOpenedSession()?.let(::openRouted)
    }

    /**
     * A session of one of the computers (a tapped push or followed session, also one that launched
     * the app), over that computer's list: the computer is selected as soon as it's listed, the
     * session's page opens at once (with what this phone has of it, and the link's note:
     * connecting…) and fills in as the computer answers. If the session isn't there after
     * [ROUTED_WAIT], or the computer says it's gone, the page goes, the list stays and a message says why.
     */
    fun openRouted(routedKey: String) {
        val r = splitRoutedKey(routedKey) ?: return
        timing("deep link")
        dropRouted()
        routed = Routed(r.desktop, r.key, scope.launch {
            delay(ROUTED_WAIT)
            routedTimedOut()
        })
        if (desktops.all.none { it.id == r.desktop }) scope.launch { desktops.refresh() }
        advanceRouted()
    }

    /** The routed session one step on, as far as what's known allows: its computer selected, its page open, done once the computer lists it. */
    private fun advanceRouted() {
        val r = routed ?: return
        val ui = ui ?: return
        val desktop = desktops.all.firstOrNull { it.id == r.desktop } ?: return // Until the list has it.
        if (!r.opened) {
            if (session.computerKey(desktop.id) == null) {
                desktops.select(desktop.id)
                return giveUpRouted("Scan ${desktop.name}’s code to open its sessions.")
            }
            if (desktops.selected?.id != desktop.id) return desktops.select(desktop.id) // Comes back here.
            val t = remote
            if (t == null || t.desktopId != desktop.id) return // Until its remote is made.
            timing("session page")
            ui.popToHome()
            ui.openSession(t, r.key)
            r.opened = true
            r.remote = t
            val l: () -> Unit = { advanceRouted() }
            r.listener = l
            t.addListener(l)
        }
        // The person went back from it: nothing more to wait for.
        if (!ui.showingSession(r.key)) return dropRouted()
        val t = r.remote!!
        // What the computer says now, not what this phone kept.
        if (!t.online || t.fromCache) return
        if (t.session(r.key) != null) {
            timing("session shown")
            return dropRouted()
        }
        giveUpRouted("That session isn’t on ${desktop.name} anymore.")
    }

    private fun routedTimedOut() {
        val r = routed ?: return
        val name = desktops.all.firstOrNull { it.id == r.desktop }?.name
        giveUpRouted(
            when {
                name == null -> "That session’s computer isn’t on this server."
                r.remote?.link == TerminalLink.unreachable -> "Can't reach ${session.userName}, so that session didn't open."
                else -> "$name didn't answer in time, so that session didn't open. It opens from the list once $name answers."
            },
        )
    }

    /** Stops waiting for the routed session: its page goes (the list stays) and [why] shows. */
    private fun giveUpRouted(why: String) {
        val r = routed
        dropRouted()
        timing("deep link gave up")
        if (r != null && r.opened) ui?.closeSession(r.key)
        ui?.toast(why)
    }

    private fun dropRouted() {
        val r = routed ?: return
        routed = null
        r.timer.cancel()
        r.listener?.let { r.remote?.removeListener(it) }
    }

    override fun dispose() {
        jobs.forEach { it.cancel() }
        dropRouted()
        desktops.removeListener(syncListener)
        session.removeListener(syncListener)
        session.removeListener(linkListener)
        remote?.let(::dropRemote)
        remote = null
        if (!demo) desktops.dispose()
        super.dispose()
    }

    companion object {
        /** How long a tapped session (a push, a followed session's link) may take to come before the phone gives up on it. */
        val ROUTED_WAIT = 20.seconds
        private val REFRESH_EVERY = 30.seconds
    }
}
