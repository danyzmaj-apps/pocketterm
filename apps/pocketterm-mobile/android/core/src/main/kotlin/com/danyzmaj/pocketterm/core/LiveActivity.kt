package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import java.time.Instant

// Coding sessions followed on the phone: Android ongoing notifications (SessionActivities.kt;
// iPhone Live Activities on iOS). The app starts one when a prompt goes out from the phone or on
// "Follow", and updates it itself while it's in front; otherwise the Mac tells the server
// (POST /v1/push/activity) and the server pushes to the phone's FCM token (one per followed
// session). A push carries only what's below, never text.

/** What a followed session's notification shows. */
enum class ActivityState { working, needs, done, ended }

/** What the agent waits for, when it needs you. */
enum class ActivityKind { question, approval, plan }

/** A followed session's [state] and, when it needs you, what for ([kind]). */
data class ActivityStatus(val state: ActivityState, val kind: ActivityKind? = null)

/**
 * What a session's activity shows: its agent asks something, works, or has stopped (done). A
 * picker the person opened from the phone isn't the agent asking.
 */
fun activityStatus(busy: Boolean, ask: LiveAsk? = null): ActivityStatus = when (ask?.kind) {
    AskKind.questions -> ActivityStatus(ActivityState.needs, ActivityKind.question)
    AskKind.approval -> ActivityStatus(ActivityState.needs, ActivityKind.approval)
    AskKind.plan -> ActivityStatus(ActivityState.needs, ActivityKind.plan)
    AskKind.menu, null -> ActivityStatus(if (busy) ActivityState.working else ActivityState.done)
}

/** The same for a session in the Mac's state; null: it's gone (ended). */
fun summaryStatus(s: LiveSummary?): ActivityStatus =
    if (s == null) ActivityStatus(ActivityState.ended) else activityStatus(busy = s.busy, ask = s.ask)

/** The `state` and `kind` of a push or a channel call. */
fun activityJson(s: ActivityStatus): JsonObject = jsonOf("state" to s.state.name).plusIfNotNull("kind", s.kind?.name)

/**
 * Phone: the sessions followed on [remote]'s computer, kept current from it while the app is in
 * front, and their push tokens handed to the server. The platform side and the server know a
 * session by its routedKey (Live.kt), this by its own key.
 *
 * Confined to [scope], as [TerminalRemote].
 */
class LiveActivities(
    private val server: Server,
    private val remote: TerminalRemote,
    private val native: Native,
    private val scope: CoroutineScope,
    /** Milliseconds since epoch. */
    private val clock: () -> Long = System::currentTimeMillis,
) : ChangeNotifier() {
    private class Shown(val status: ActivityStatus, val since: Long)

    /** Followed sessions: what each activity shows and since when. Null: one still running from before this launch, which only pushes have updated. */
    private val shown = linkedMapOf<String, Shown?>()

    /** When a prompt last went to a session: its agent may not have reported busy yet, so for a while "done" is taken to be from before it. */
    private val prompted = mutableMapOf<String, Long>()

    /** Sessions whose push token the server has, as `routed key\ntoken`: on Android one token serves every followed session. */
    private val registered = mutableSetOf<String>()

    private val sync: () -> Unit = { syncNow() }

    init {
        remote.addListener(sync)
        scope.launch { load() }
    }

    fun following(key: String): Boolean = shown.containsKey(key)

    private fun routed(key: String) = routedKey(remote.desktopId, key)

    /** [routed]'s session key if it's on this computer. */
    private fun mine(routed: String): String? {
        val r = splitRoutedKey(routed)
        return if (r != null && r.desktop == remote.desktopId) r.key else null
    }

    /** The activities running from before; the server learns every token, whichever computer its session is on. */
    private suspend fun load() {
        for (a in native.liveActivities()) {
            if (splitRoutedKey(a.key) == null) continue
            mine(a.key)?.let { if (!shown.containsKey(it)) shown[it] = null }
            val token = a.token
            if (token != null) scope.launch { register(a.key, token) }
        }
        syncNow()
        notifyListeners()
    }

    /**
     * Starts following [key], shown as [title]; [status] if known better than the Mac's state (a
     * prompt just sent). False: notifications are off for PocketTerm, or the session isn't there.
     */
    suspend fun follow(key: String, title: String, status: ActivityStatus? = null): Boolean {
        val s = remote.session(key) ?: return false
        val next = Shown(status ?: summaryStatus(s), clock())
        val started = native.startActivity(
            key = routed(key),
            title = title,
            project = s.cwd.split(Regex("""[\\/]""")).lastOrNull { it.isNotEmpty() } ?: s.cwd,
            state = next.status.state.name,
            kind = next.status.kind?.name,
            since = Instant.ofEpochMilli(next.since),
        )
        if (started) {
            shown[key] = next
            notifyListeners()
        }
        return started
    }

    /** A prompt went to [key]: it's working now, followed from here on, if the phone can show one more. */
    suspend fun prompted(key: String, title: String) {
        prompted[key] = clock()
        val working = ActivityStatus(ActivityState.working)
        if (!following(key)) {
            try {
                follow(key, title, working)
            } catch (_: TooManyActivities) {
                return // The prompt went all the same.
            }
        } else if (shown[key]?.status?.state != ActivityState.working) {
            show(key, working)
        }
    }

    /** The person stops following [key]: the activity goes at once. */
    suspend fun stop(key: String) {
        shown.remove(key)
        notifyListeners()
        native.endActivity(routed(key), immediate = true)
    }

    /** From the platform side ([Native.events]): activityToken, activityEnded, for a [routedKey]. */
    fun onNative(event: String, args: Map<String, Any?>) {
        val routed = args["key"] as? String
        val token = args["token"] as? String
        if (routed == null || splitRoutedKey(routed) == null) return
        when (event) {
            "activityToken" -> if (token != null) scope.launch { register(routed, token) }
            "activityEnded" -> {
                if (token != null) {
                    registered.remove("$routed\n$token")
                    scope.launch { push("activity_end", jsonOf("token" to token, "session" to routed)) }
                }
                mine(routed)?.let { key ->
                    shown.remove(key)
                    prompted.remove(key)
                    notifyListeners()
                }
            }
        }
    }

    private suspend fun register(routed: String, token: String) {
        if (!registered.add("$routed\n$token")) return
        // An Android phone's plain end names the session only by its tag (sessionTag), which the server can't make.
        val ref = if (pushPlatform == "android") ref(routed) else null
        val body = jsonOf("token" to token, "session" to routed, "platform" to pushPlatform).plusIfNotNull("ref", ref)
        if (!push("activity_register", body)) registered.remove("$routed\n$token")
    }

    /** [routed]'s [sessionTag] under its computer's key; null without the key (nothing from it would open anyway). */
    private suspend fun ref(routed: String): String? {
        val desktop = splitRoutedKey(routed)?.desktop
        val key = if (desktop == remote.desktopId) {
            remote.key
        } else {
            val keys = try {
                native.channelKeys()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                emptyMap()
            }
            ChannelKey.tryParse(keys[desktop])
        }
        return key?.let { sessionTag(it, routed) }
    }

    private suspend fun push(action: String, body: JsonObject): Boolean = try {
        server.push(action, body)
        true
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        debugPrint("PocketTerm: Live Activity $action: $e")
        false
    }

    private suspend fun show(key: String, status: ActivityStatus) {
        val since = clock()
        // Taken at once, before the platform answers, so the next sync compares with it.
        shown[key] = Shown(status, since)
        native.updateActivity(key = routed(key), state = status.state.name, kind = status.kind?.name, since = Instant.ofEpochMilli(since))
    }

    private fun showLater(key: String, status: ActivityStatus) {
        val since = clock()
        shown[key] = Shown(status, since)
        scope.launch {
            native.updateActivity(key = routed(key), state = status.state.name, kind = status.kind?.name, since = Instant.ofEpochMilli(since))
        }
    }

    /** The Mac's state changed: each followed session's activity follows it. */
    private fun syncNow() {
        val macState = remote.online && !remote.fromCache
        for (key in shown.keys.toList()) {
            val s = remote.session(key)
            if (s == null) {
                if (!macState) continue
                shown.remove(key)
                prompted.remove(key)
                scope.launch { native.endActivity(routed(key)) }
                notifyListeners()
                continue
            }
            val status = summaryStatus(s)
            val current = shown[key]
            val promptedAt = prompted[key]
            if (status.state == ActivityState.done && promptedAt != null && clock() - promptedAt < PROMPT_WAIT_MS) continue
            if (status.state != ActivityState.done) prompted.remove(key)
            if (current == null) {
                // Pushes have kept it current; its timer stays.
                shown[key] = Shown(status, clock())
            } else if (current.status != status) {
                showLater(key, status)
            }
        }
    }

    override fun dispose() {
        remote.removeListener(sync)
        super.dispose()
    }

    private companion object {
        const val PROMPT_WAIT_MS = 30_000L
    }
}
