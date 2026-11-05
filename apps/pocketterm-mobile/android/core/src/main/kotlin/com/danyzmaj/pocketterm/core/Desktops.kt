package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.JsonObject
import java.time.Instant
import kotlin.time.Duration
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * A computer running PocketTerm on this server (GET /v1/desktops): it refreshes [seenAt] every
 * minute while its terminal bridge runs, and the phone talks to it on its own topic, its id.
 */
data class Desktop(
    /** 8 characters, a-z and 0-9. */
    val id: String,
    val name: String,
    /** `macos` or `windows`. */
    val platform: String,
    val seenAt: Instant,
) {
    val windows: Boolean get() = platform == "windows"

    /** It has said so within two and a half of its one-minute beats. */
    val online: Boolean get() = sinceNow(seenAt) < onlineWithin

    fun toJson(): JsonObject = jsonOf("id" to id, "name" to name, "platform" to platform, "seen_at" to dartIsoUtc(seenAt))

    companion object {
        /** How recently a computer has to have said it's there to count as [online]. */
        val onlineWithin: Duration = 150.seconds

        /** Throws on a row without the fields, as the Dart casts did. */
        fun fromJson(j: JsonObject): Desktop = Desktop(
            id = j["id"].str ?: throw IllegalArgumentException("id"),
            name = j["name"].str ?: throw IllegalArgumentException("name"),
            platform = j["platform"].str ?: throw IllegalArgumentException("platform"),
            seenAt = parseDartDateTime(j["seen_at"].str ?: throw IllegalArgumentException("seen_at"))
                ?: throw IllegalArgumentException("seen_at"),
        )
    }
}

private fun sinceNow(t: Instant): Duration = (System.currentTimeMillis() - t.toEpochMilli()).milliseconds

/**
 * Phone: the server's computers, newest seen first, and the one the Terminal tab shows
 * ([selected]). [cached]: the list as last seen, [saved]: the computer last shown, both from
 * before this launch (shown until the server says otherwise); [onChanged] keeps them for the next one.
 */
class Desktops(
    private val server: Server,
    cached: List<Desktop> = emptyList(),
    saved: String? = null,
    /** The list or the selection changed. */
    private val onChanged: ((all: List<Desktop>, selected: String?) -> Unit)? = null,
) : ChangeNotifier() {
    var all: List<Desktop> = cached
        private set

    /** The server has answered since launch. */
    var loaded: Boolean = false
        private set

    private var selectedId: String? = saved

    val selected: Desktop? get() = all.firstOrNull { it.id == selectedId }

    /** Why the last [refresh] got no list (the server can't be reached, say); null once one came. */
    var error: String? = null
        private set

    private var disposed = false
    private var wanted: String? = null

    /**
     * Fetches the list; on failure the last one stays, and [error] says why. One that comes back
     * after [dispose] (signed out meanwhile) is dropped: it would keep the old server's computers
     * for the next sign-in.
     */
    suspend fun refresh() {
        try {
            val rows = server.desktops()
            timing("computers listed")
            if (!disposed) apply(rows)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            timing("computers failed")
            debugPrint("PocketTerm: computers: $e")
            val why = if (e is ServerException) e.message else "$e"
            if (disposed || why == error) return
            error = why
            notifyListeners()
        }
    }

    override fun dispose() {
        disposed = true
        super.dispose()
    }

    /** The rows from the server, newest seen first. */
    fun apply(rows: List<JsonObject>) {
        all = rows.map { Desktop.fromJson(it) }.filter { sinceNow(it.seenAt) < keepFor }
        loaded = true
        error = null
        pick()
        onChanged?.invoke(all, selectedId)
        notifyListeners()
    }

    /** The person shows [id]'s sessions. */
    fun select(id: String) {
        if (id == selectedId || all.none { it.id == id }) return
        selectedId = id
        onChanged?.invoke(all, selectedId)
        notifyListeners()
    }

    /** The person just scanned [id]'s code: it's shown now if listed, else as soon as [apply] lists it, whichever computer was seen last. */
    fun show(id: String) {
        if (all.any { it.id == id }) {
            wanted = null
            select(id)
        } else {
            wanted = id
        }
    }

    /**
     * The one asked for by [show] once listed; else the one shown stays while listed; else the
     * newest seen (kept from then on, so it doesn't flip as computers take turns being newest); else none.
     */
    private fun pick() {
        val w = wanted
        if (w != null && all.any { it.id == w }) {
            selectedId = w
            wanted = null
        }
        if (selected == null) selectedId = all.firstOrNull()?.id
    }

    companion object {
        /** Computers seen this long ago or longer aren't listed. */
        val keepFor: Duration = 30.days
    }
}
