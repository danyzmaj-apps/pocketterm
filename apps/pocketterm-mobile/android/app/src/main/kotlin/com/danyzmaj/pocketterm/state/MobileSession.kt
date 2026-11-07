package com.danyzmaj.pocketterm.state

import com.danyzmaj.pocketterm.AndroidPreferences
import com.danyzmaj.pocketterm.core.Account
import com.danyzmaj.pocketterm.core.Backend
import com.danyzmaj.pocketterm.core.ChannelKey
import com.danyzmaj.pocketterm.core.ComputerKey
import com.danyzmaj.pocketterm.core.DartUri
import com.danyzmaj.pocketterm.core.Desktop
import com.danyzmaj.pocketterm.core.DeviceRole
import com.danyzmaj.pocketterm.core.DeviceTokens
import com.danyzmaj.pocketterm.core.Desktops
import com.danyzmaj.pocketterm.core.Native
import com.danyzmaj.pocketterm.core.NativeDeviceTokens
import com.danyzmaj.pocketterm.core.Session
import com.danyzmaj.pocketterm.core.debugPrint
import com.danyzmaj.pocketterm.core.jsonDecode
import com.danyzmaj.pocketterm.core.jsonEncode
import com.danyzmaj.pocketterm.core.jsonOf
import com.danyzmaj.pocketterm.core.pushPlatform
import com.danyzmaj.pocketterm.core.SUPABASE_GONE_NOTE
import com.danyzmaj.pocketterm.core.forgetSupabase
import com.danyzmaj.pocketterm.demo.DemoComputer
import com.danyzmaj.pocketterm.demo.demoDesktopId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import java.io.File
import kotlin.time.Duration.Companion.seconds

/**
 * The phone side of [Session]: keeps the computers' channel keys (from their QR codes) where the
 * native side reads them too (PocketTermShared: the push service opens a computer's pushes with its
 * key), registers this phone for the computer's terminal pushes, and ends the sessions it follows
 * when it leaves the server. Also the phone's preferences the screens keep (sort, folds, looks…).
 *
 * Confined to the main thread ([scope]).
 */
class MobileSession(
    private val prefs: AndroidPreferences,
    private val native: Native,
    device: String,
    scope: CoroutineScope,
    /** Where the demo's made-up computer keeps its cache. */
    private val cacheDir: File,
    /** Whether the first-use tips start seen (E2E builds). */
    tipsStartSeen: Boolean = false,
) : Session(device, scope) {
    /** A phone signs in only with a code from the computer. */
    override val role: DeviceRole get() = DeviceRole.phone

    override val deviceTokens: DeviceTokens = NativeDeviceTokens(native)

    /** The phone opens on what it had (its computers, their sessions, from cache) while the server is asked whether the sign-in still holds. */
    override val signInAtOnce: Boolean get() = true

    override suspend fun loadBackend(): Backend? = Backend.load(native)

    override suspend fun saveBackend(backend: Backend) = backend.save(native)

    override suspend fun clearBackend() = Backend.clear(native)

    /** The Keystore didn't let PocketTerm keep the sign-in. */
    override fun storageProblem(e: Throwable): String? =
        if (e is java.security.GeneralSecurityException) {
            "This phone couldn't keep the sign-in in its secure storage ($e). Try again."
        } else {
            null
        }

    private val computerKeys = mutableMapOf<String, ChannelKey>()

    /**
     * Computer [desktopId]'s channel key; null while this phone hasn't scanned that computer's code:
     * the computer is locked, nothing from it shows and nothing goes to it.
     */
    override fun computerKey(desktopId: String): ChannelKey? {
        val d = demo
        if (d != null && user == null && desktopId == demoDesktopId) return d.remote.key
        return computerKeys[desktopId]
    }

    /** Until [start] has read what this phone kept (its server, sign-in and computer keys): nothing shows yet, rather than setup for a moment. */
    var launching: Boolean = false
        private set

    suspend fun startPhone(links: Flow<String>) {
        launching = true
        try {
            forgetOldApp()
            loadComputerKeys()
            start(links)
        } finally {
            launching = false
            notifyListeners()
        }
    }

    /**
     * A followed session's link (`pocketterm://session?key=<routed key>`, Android's ongoing
     * notification's), kept until the home page takes it ([takeOpenedSession]): the one that
     * launched the app comes before there's a home page.
     */
    override fun onOtherLink(link: String) {
        val uri = DartUri.tryParse(link) ?: return
        if (uri.scheme != "pocketterm" || uri.host != "session") return
        val key = uri.queryParameters["key"]
        if (key.isNullOrEmpty()) return
        openedSession = key
        notifyListeners()
    }

    private var openedSession: String? = null

    /** The routed key of the session a link opened, once. */
    fun takeOpenedSession(): String? = openedSession.also { openedSession = null }

    /**
     * PocketTerm no longer runs on Supabase projects ([forgetSupabase]): a phone signed in through
     * one is signed out here and told to scan its computer's new code. What that left goes too: the
     * Supabase session and the computers list it cached, and the sessions it followed. The tips
     * seen and the list's order stay. Once: nothing is left to forget after.
     */
    suspend fun forgetOldApp() {
        try {
            if (!forgetSupabase(native)) return
            signedOutReason = SUPABASE_GONE_NOTE
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: the old app’s data not removed: $e")
            return
        }
        for (k in prefs.keys()) {
            // pocketterm_push_token: written by older versions, never read.
            if (k.startsWith("sb-") || k.startsWith("supabase") || k == "pocketterm_push_token" || k == DESKTOP_KEY || k == DESKTOPS_KEY) {
                prefs.remove(k)
            }
        }
        endActivities()
    }

    /** The keys the native side keeps. */
    suspend fun loadComputerKeys() {
        try {
            for ((id, value) in native.channelKeys()) ChannelKey.tryParse(value)?.let { computerKeys[id] = it }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: computer keys not read: $e")
        }
        notifyListeners()
    }

    /** The computer whose code was last scanned, until the home page shows it ([takeScannedComputer]). */
    private var scanned: String? = null

    /** The computer just scanned, once: the home page shows it rather than whichever was seen last. */
    fun takeScannedComputer(): String? = scanned.also { scanned = null }

    override suspend fun addComputerKey(computer: ComputerKey) {
        scanned = computer.desktop
        if (computerKeys[computer.desktop] != computer.key) {
            native.setChannelKey(computer.desktop, computer.key.toBase64())
            computerKeys[computer.desktop] = computer.key
        }
        notifyListeners()
    }

    // ------------------------------------------------------------------ demo

    /** "Try the demo": a made-up computer answered on this phone (demo/Demo.kt), shown while signed out; null otherwise. */
    var demo: DemoComputer? = null
        private set

    fun enterDemo() {
        if (user != null || demo != null) return
        demo = DemoComputer(File(cacheDir, "demo-${System.nanoTime()}").apply { mkdirs() }, scope)
        notifyListeners()
    }

    /** Back to the setup screen (or on, once signed in). The demo goes once nothing shows it. */
    fun exitDemo() {
        val d = demo ?: return
        demo = null
        notifyListeners()
        scope.launch { d.dispose() }
    }

    // ------------------------------------------------------------------ list preferences

    /** The Terminal list's projects (folders) showing only their heading. */
    val collapsedProjects: Set<String> get() = prefs.getStringList(FOLDED_KEY)?.toSet() ?: emptySet()

    fun setCollapsedProjects(cwds: Set<String>) = prefs.setStringList(FOLDED_KEY, cwds.toList())

    /** How the Terminal list orders its projects; by name until chosen. */
    val projectSort: ProjectSort get() = ProjectSort.entries.firstOrNull { it.key == prefs.getString(SORT_KEY) } ?: ProjectSort.byName

    fun setProjectSort(sort: ProjectSort) {
        prefs.setString(SORT_KEY, sort.key)
        notifyListeners()
    }

    /** The omp profile whose sessions the list shows for computer [desktop] ('' the default); null, until chosen, shows every profile's. */
    fun profileFilter(desktop: String): String? = prefs.getString("${PROFILE_FILTER_KEY}_$desktop")

    fun setProfileFilter(desktop: String, profile: String?) {
        if (profile == null) prefs.remove("${PROFILE_FILTER_KEY}_$desktop") else prefs.setString("${PROFILE_FILTER_KEY}_$desktop", profile)
        notifyListeners()
    }

    /** The omp profile a new session on computer [desktop] starts in, as last picked; '' (the default) until then. */
    fun newSessionProfile(desktop: String): String = prefs.getString("${NEW_PROFILE_KEY}_$desktop") ?: ""

    fun setNewSessionProfile(desktop: String, profile: String) = prefs.setString("${NEW_PROFILE_KEY}_$desktop", profile)

    /**
     * The names and colours the person gave rows in the list, by computer and row key. A row keeps
     * them while its window lives; a window that closes leaves only a stale entry, which costs nothing.
     */
    fun tileLooks(desktop: String): Map<String, TileLook> =
        looks().filterKeys { it.startsWith("$desktop|") }.mapKeys { it.key.substring(desktop.length + 1) }

    fun setTileLooks(desktop: String, looks: Map<String, TileLook>) {
        val all = looks().filterKeys { !it.startsWith("$desktop|") } +
            looks.filterValues { it.name != null || it.color != null }.mapKeys { "$desktop|${it.key}" }
        prefs.setString(LOOKS_KEY, jsonEncode(JsonObject(all.mapValues { it.value.toJson() })))
        notifyListeners()
    }

    private fun looks(): Map<String, TileLook> = try {
        val json = jsonDecode(prefs.getString(LOOKS_KEY) ?: "{}") as? JsonObject ?: JsonObject(emptyMap())
        json.mapNotNull { (k, v) -> (v as? JsonObject)?.let { k to TileLook.fromJson(it) } }.toMap()
    } catch (_: Exception) {
        emptyMap()
    }

    /** The first-use tips this phone has shown; kept across sign-outs, they're the phone's. */
    val tips = Tips(prefs, startSeen = tipsStartSeen)

    /** Per-session unsent prompts. */
    val drafts = Drafts(prefs)

    /** The account's computers, starting from the list and the choice this phone kept, and keeping them as they change. */
    fun desktops(): Desktops {
        val cached = try {
            (jsonDecode(prefs.getString(DESKTOPS_KEY) ?: "[]") as JsonArray).map { Desktop.fromJson(it as JsonObject) }
        } catch (e: Exception) {
            debugPrint("PocketTerm: computers cache: $e")
            emptyList()
        }
        return Desktops(server!!, cached = cached, saved = prefs.getString(DESKTOP_KEY)) { all, selected ->
            prefs.setString(DESKTOPS_KEY, jsonEncode(JsonArray(all.map { it.toJson() })))
            if (selected == null) prefs.remove(DESKTOP_KEY) else prefs.setString(DESKTOP_KEY, selected)
        }
    }

    // ------------------------------------------------------------------ push

    override suspend fun onSignedIn(user: Account) {
        exitDemo()
        if (pushEnabled == true) registerPush(user.device.id)
        checkNotifications()
    }

    /**
     * Whether the phone lets PocketTerm's notifications show; null until known. Notifications on here
     * but off in the phone's Settings (turned off there after saying yes) show nothing: Settings says so.
     */
    var notificationsAllowed: Boolean? = null
        private set

    /** Asks the phone again (at sign-in, coming back to the app, after a change here). */
    suspend fun checkNotifications() {
        val allowed = try {
            native.notificationsAllowed()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: notification permission not read: $e")
            null
        }
        if (allowed == notificationsAllowed) return
        notificationsAllowed = allowed
        notifyListeners()
    }

    /**
     * The person's push choice on the signed-in server (kept per server id): null until asked
     * (the push consent page), and while signed out. Nothing registers for push before it's true.
     */
    val pushEnabled: Boolean? get() = user?.let { prefs.getBool("${PUSH_CHOICE_KEY}_${it.id}") }

    private var pushChoice = 0

    /**
     * Turns push on (the system's permission, then this phone's token to the server) or off (the
     * server forgets this phone's tokens, followed sessions end and Follow goes away). False: [on],
     * but the phone didn't allow notifications, so it stays off.
     */
    suspend fun setPushEnabled(on: Boolean): Boolean {
        val u = user ?: return false
        val key = "${PUSH_CHOICE_KEY}_${u.id}"
        // A later choice (Not now while Turn on still waits) wins.
        val choice = ++pushChoice
        if (!on) {
            val was = pushEnabled ?: false
            pushUnsent = false
            prefs.setBool(key, false)
            notifyListeners()
            // Not now, the first time: nothing was registered.
            if (was) pushOff()
            return true
        }
        val registered = registerPush(u.device.id)
        if (choice != pushChoice) return true
        prefs.setBool(key, registered)
        checkNotifications()
        notifyListeners()
        return registered
    }

    /**
     * Push is on, but the server missed this phone's token (offline): it is sent again ([retryPush])
     * when the app comes back, when the computer's connection is back, and when Settings opens.
     */
    var pushUnsent: Boolean = false
        private set

    /** A missed token is on its way to the server again: Settings shows that instead of the old warning. */
    var pushRegistering: Boolean = false
        private set
    private var pushTried: Long? = null

    /**
     * Sends a token the server missed again, one try at a time. [force] (the app coming back,
     * Settings opening) tries at once; otherwise (the connection back) not within 30 s of the last
     * try, so a server that keeps refusing isn't asked on every state.
     */
    suspend fun retryPush(force: Boolean = false) {
        val user = user
        if (!pushUnsent || pushRegistering || user == null || pushEnabled != true) return
        val tried = pushTried
        val now = System.currentTimeMillis()
        if (!force && tried != null && now - tried < 30_000) return
        pushTried = now
        pushRegistering = true
        notifyListeners()
        try {
            registerPush(user.device.id)
        } finally {
            pushRegistering = false
            notifyListeners()
        }
    }

    /**
     * Hands this phone's FCM token to the server, which from then on relays the computer's terminal
     * news, sealed by each computer with its key. False: not allowed, no token, or none within
     * [PUSH_TOKEN_WAIT]. A server that missed it (offline) leaves [pushUnsent] for [retryPush].
     */
    private suspend fun registerPush(deviceId: String): Boolean {
        val token = try {
            withTimeoutOrNull(PUSH_TOKEN_WAIT) { native.registerPush() }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: no push token: $e")
            null
        } ?: return false
        if (user?.device?.id != deviceId) return true
        var unsent = false
        try {
            server!!.push("register", jsonOf("token" to token, "label" to device, "platform" to pushPlatform))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: push registration failed: $e")
            unsent = true
        }
        if (unsent != pushUnsent) {
            pushUnsent = unsent
            notifyListeners()
        }
        return true
    }

    /** Push off: followed sessions end here, and the server forgets every token of this phone. */
    private suspend fun pushOff() {
        endActivities()
        tryServer("push unregister") { server!!.push("unregister", jsonOf()) }
    }

    /** FCM handed over a new token (`pushToken`); the server needs it, if push is on. */
    suspend fun pushTokenChanged() {
        val user = user ?: return
        if (pushEnabled == true) registerPush(user.device.id)
    }

    override suspend fun onSigningOut() {
        val push = pushEnabled ?: false
        forgetHere()
        // The server forgets this phone's push token and its followed sessions'.
        if (push) tryServer("push unregister") { server!!.push("unregister", jsonOf()) }
    }

    /** However the sign-in went, also without [signOut] here (the computer signed this phone out): its followed sessions leave this phone. */
    override suspend fun onSignedOut() {
        forgetHere()
    }

    /**
     * Drops what this phone keeps for the server: the push choice (the next sign-in asks again),
     * every computer's key (the next sign-in scans a code, which brings its computer's), and the
     * followed sessions, ended at once.
     */
    private suspend fun forgetHere() {
        openedSession = null
        pushUnsent = false
        pushRegistering = false
        pushTried = null
        // Every server's: the sign-in may already be gone, and with it its id.
        for (k in prefs.keys()) if (k.startsWith("${PUSH_CHOICE_KEY}_")) prefs.remove(k)
        prefs.remove(DESKTOP_KEY)
        prefs.remove(DESKTOPS_KEY)
        try {
            native.removeAllChannelKeys()
            computerKeys.clear()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: computer keys not removed: $e")
        }
        endActivities()
    }

    /** The followed sessions (ongoing notifications) end at once. */
    private suspend fun endActivities() {
        try {
            for (a in native.liveActivities()) native.endActivity(a.key, immediate = true)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: followed sessions not ended: $e")
        }
    }

    /** One server call of a clean-up; a failed one (offline) doesn't stop the rest. */
    private suspend fun tryServer(what: String, call: suspend () -> Unit) {
        try {
            call()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: $what failed: $e")
        }
    }

    /** Lets screens tell observers the session's preferences changed (a draft, a look). */
    fun changed() = notifyListeners()

    companion object {
        /** How long the phone may take to hand over its push token before [setPushEnabled] gives up. */
        val PUSH_TOKEN_WAIT = 15.seconds

        const val PUSH_CHOICE_KEY = "pocketterm_push_on"
        const val FOLDED_KEY = "pocketterm_terminal_folded"
        const val SORT_KEY = "pocketterm_terminal_sort"
        const val PROFILE_FILTER_KEY = "pocketterm_profile_filter"
        const val NEW_PROFILE_KEY = "pocketterm_new_profile"
        const val LOOKS_KEY = "pocketterm_tile_looks"
        const val DESKTOP_KEY = "pocketterm_desktop"
        const val DESKTOPS_KEY = "pocketterm_desktops"
    }
}
