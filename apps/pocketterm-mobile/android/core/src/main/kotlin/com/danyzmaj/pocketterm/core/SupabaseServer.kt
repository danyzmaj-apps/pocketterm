package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import okhttp3.OkHttpClient
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/** A Realtime token for this device, when it runs out, and the project's publishable key (Realtime takes it with every connection). */
data class LiveToken(val token: String, val expires: Instant, val apikey: String)

/**
 * PocketTerm set up on a Supabase project (apps/pocketterm-desktop/supabase): the same REST paths
 * as the PocketTerm server under `<project>/functions/v1/pocketterm`, so everything but the live
 * channel is [PocketTermServerClient]'s. The live channel is Supabase Realtime broadcast on
 * private topics: the function mints this device a Realtime token for 10 minutes at a time
 * (POST /v1/live/token), which Realtime checks against the devices still signed in on every join
 * and refresh.
 */
open class SupabaseServerClient(backend: Backend, tokens: DeviceTokens) : PocketTermServerClient(backend, tokens) {
    /** Computer only: a setup link for another computer (POST /v1/setup/new). The one before stops working; nobody is signed out. */
    suspend fun newSetupLink(): String {
        val setup = request("POST", "/v1/setup/new").obj?.get("setup").str
            ?: throw ServerException(500, "internal", "The server didn't send a setup link.")
        return backend.linkWithSetup(setup)
    }

    /** A Realtime token for this device, when it runs out, and the project's publishable key. Open: tests stand in their own. */
    open suspend fun liveToken(): LiveToken {
        val answer = request("POST", "/v1/live/token").obj
        val token = answer?.get("token").str
        val expires = answer?.get("expires").long
        val apikey = answer?.get("apikey").str
        if (token == null || expires == null || apikey == null) {
            throw ServerException(500, "internal", "The server didn't send a live channel token.")
        }
        return LiveToken(token, Instant.ofEpochMilli(expires * 1000), apikey)
    }

    override suspend fun connectLive(): LiveSocket {
        val first = liveToken()
        val url = wsUrl(backend.url) + "/realtime/v1/websocket?" +
            "apikey=${DartUri.encodeQueryComponent(first.apikey)}&vsn=1.0.0"
        val ws = OkHttpLiveSocket.connect(realtimeHttp, url)
        return RealtimeLive(this, ws, first)
    }

    private companion object {
        val realtimeHttp: OkHttpClient by lazy { Http.base.newBuilder().connectTimeout(20, TimeUnit.SECONDS).build() }
    }
}

/**
 * Supabase Realtime (Phoenix channels, protocol 1.0.0) as a [LiveSocket]: PROTOCOL.md's frames in
 * and out. A `join` joins the private channel `realtime:<topic>` with this device's token, `send`
 * broadcasts, `ping` is Phoenix's heartbeat. The token is renewed a minute before it runs out; a
 * refusal (the device was signed out) closes this with 4003. A join Realtime refuses, or a channel
 * it closes, closes this too (the live channel connects again), after asking the server whether
 * the sign-in still holds. `pt.left` on a topic (someone was signed out) asks it too.
 *
 * Its state lives on one confined coroutine dispatcher: [add] may be called from any thread.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RealtimeLive internal constructor(
    private val server: SupabaseServerClient,
    private val ws: LiveSocket,
    token: LiveToken,
    /** Milliseconds since epoch; tests move it. */
    private val clock: () -> Long = System::currentTimeMillis,
    dispatcher: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.Default.limitedParallelism(1),
) : LiveSocket {
    private val confined = dispatcher
    private val scope = CoroutineScope(SupervisorJob() + confined)
    private val out = Channel<String>(Channel.UNLIMITED)
    private var outClosed = false
    private var token: LiveToken = token
    private var renew: Job? = null
    private var code: Int? = null
    private var ref = 0

    /** The topics joined (or joining) and their join refs. */
    private val joins = linkedMapOf<String, String>()

    /** Join refs waiting for Realtime's answer, and their topics. */
    private val joining = linkedMapOf<String, String>()

    /** Heartbeat refs waiting for an answer. */
    private val beats = mutableSetOf<String>()

    private val sub: Job = scope.launch {
        ws.frames.collect { receive(it) }
        gone()
    }

    init {
        scope.launch { renewLater() }
    }

    override val frames: Flow<String> = out.receiveAsFlow()

    override val closeCode: Int? get() = code ?: ws.closeCode

    private fun next(): String = "${++ref}"

    private fun phx(topic: String, event: String, payload: JsonObject, ref: String?, joinRef: String? = null) {
        if (outClosed) return
        val frame = linkedMapOf<String, Any?>("topic" to topic, "event" to event, "payload" to payload, "ref" to ref)
        if (joinRef != null) frame["join_ref"] = joinRef
        ws.add(jsonEncode(frame.toJsonElement()))
    }

    private fun emit(frame: JsonObject) {
        if (!outClosed) out.trySend(jsonEncode(frame))
    }

    override fun add(frame: String) {
        scope.launch { handle(frame) }
    }

    private fun handle(frame: String) {
        val f = jsonDecodeOrNull(frame).obj ?: return
        val topic = f["topic"].str
        when (f["t"].str) {
            "join" -> {
                if (topic == null) return
                val ref = next()
                joins[topic] = ref
                joining[ref] = topic
                phx(
                    "realtime:$topic",
                    "phx_join",
                    jsonOf(
                        "config" to jsonOf(
                            "broadcast" to jsonOf("self" to false, "ack" to false),
                            "presence" to jsonOf("key" to "", "enabled" to false),
                            "private" to true,
                        ),
                        "access_token" to token.token,
                    ),
                    ref = ref,
                    joinRef = ref,
                )
            }
            "send" -> {
                val event = f["event"].str
                if (topic == null || event == null || !f.containsKey("payload")) return
                val payload: JsonElement = f["payload"] ?: JsonNull
                val joinRef = joins[topic]
                if (joinRef == null || joining.containsValue(topic)) {
                    return emit(jsonOf("t" to "error", "error" to "not_joined", "message" to "Join $topic first."))
                }
                phx(
                    "realtime:$topic",
                    "broadcast",
                    jsonOf("type" to "broadcast", "event" to event, "payload" to payload),
                    ref = next(),
                    joinRef = joinRef,
                )
            }
            "leave" -> {
                if (topic == null) return
                val joinRef = joins.remove(topic)
                if (joinRef != null) phx("realtime:$topic", "phx_leave", JsonObject(emptyMap()), ref = next(), joinRef = joinRef)
            }
            "ping" -> {
                val ref = next()
                beats.add(ref)
                phx("phoenix", "heartbeat", JsonObject(emptyMap()), ref = ref)
            }
        }
    }

    private fun receive(data: String) {
        val m = jsonDecodeOrNull(data).obj ?: return
        val topic = (m["topic"].str ?: "").replaceFirst("realtime:", "")
        val payload = m["payload"]
        val ref = m["ref"].str
        when (m["event"].str) {
            "phx_reply" -> when {
                ref != null && beats.remove(ref) -> emit(jsonOf("t" to "pong"))
                ref != null && joining.containsKey(ref) -> {
                    val joined = joining.remove(ref)!!
                    if (payload.obj?.get("status").str == "ok") return emit(jsonOf("t" to "joined", "topic" to joined))
                    debugPrint("PocketTerm: Realtime refused $joined: ${payload.obj?.get("response") ?: payload}")
                    refused()
                }
            }
            "broadcast" -> if (joins.containsKey(topic)) {
                val event = payload.obj?.get("event").str
                if (event != null && payload.obj!!.containsKey("payload")) {
                    // Someone was signed out: this device asks whether it was.
                    if (event == "pt.left") {
                        scope.launch { server.recheck() }
                        return
                    }
                    emit(jsonOf("t" to "msg", "topic" to topic, "event" to event, "payload" to payload.obj!!["payload"]))
                }
            }
            "phx_error", "phx_close" -> if (joins.containsKey(topic)) {
                debugPrint("PocketTerm: Realtime closed $topic (${m["event"].str})")
                refused()
            }
            "system" -> if (payload.obj?.get("status").str == "error") {
                debugPrint("PocketTerm: Realtime: ${payload.obj?.get("message")}")
                refused()
            }
        }
    }

    /** Realtime turned this device away or closed its channel (an old token, a device signed out meanwhile): ask the server, then connect again. */
    private fun refused() {
        scope.launch { server.recheck() }
        scope.launch { close() }
    }

    private fun renewLater() {
        val wait = (token.expires.toEpochMilli() - clock()).milliseconds - 1.minutes
        val delayFor: Duration = if (wait < 10.seconds) 10.seconds else wait
        renew = scope.launch {
            delay(delayFor)
            renewNow()
        }
    }

    private suspend fun renewNow() {
        // This runs as the renew job: closing must not cancel it halfway.
        renew = null
        try {
            token = server.liveToken()
        } catch (e: ServerException) {
            if (e.status == 401) return close(4003)
            renew = scope.launch {
                delay(15.seconds)
                renewNow()
            }
            return
        }
        if (outClosed) return
        for ((topic, joinRef) in joins.entries.toList()) {
            phx("realtime:$topic", "access_token", jsonOf("access_token" to token.token), ref = next(), joinRef = joinRef)
        }
        renewLater()
    }

    private fun gone() {
        renew?.cancel()
        closeOut()
    }

    private fun closeOut() {
        if (!outClosed) {
            outClosed = true
            out.close()
        }
    }

    override suspend fun close(code: Int) {
        withContext(confined) {
            if (this@RealtimeLive.code == null) this@RealtimeLive.code = if (code == 1000) null else code
            renew?.cancel()
            closeOut()
        }
        sub.cancel()
        runCatching { ws.close(1000) }
    }
}
