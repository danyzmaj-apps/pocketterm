package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

/**
 * PocketTerm on a Supabase project, faked on loopback: the function's REST paths
 * (`/functions/v1/pocketterm/v1/…`) go to a real [OwnServer] behind it, as the function answers
 * the same; the two the PocketTerm server lacks are its own — POST /v1/setup/new (a computer
 * replaces the setup token) and POST /v1/live/token (a Realtime token for 10 minutes, [ttlSeconds])
 * — and so is Supabase Realtime (`/realtime/v1/websocket`, Phoenix channels 1.0.0): private
 * topics joined with a live token whose device is still signed in, broadcast to the others on the
 * topic, heartbeats, `access_token` refreshes, and `pt.left` on every joined topic once a device
 * leaves, is revoked or the server is erased (the function's tell_left).
 */
class FakeSupabase private constructor(private val own: OwnServer) : TestBackend {
    private val http = OkHttpClient()
    private val web = MockWebServer()
    private val lock = Any()

    /** The project's setup token at the start (the Dart tests' fixed one); [OwnServer.setupToken] stands behind it. */
    override val setupToken: String = own.setupToken

    /** The one it takes now: POST /v1/setup/new replaces it. */
    @Volatile
    private var current: String = own.setupToken

    override val relayed: MutableList<JsonObject> get() = own.relayed

    /** How long the live tokens it mints last. */
    @Volatile
    var ttlSeconds: Long = 600

    /** The live tokens it minted: the device token each stands for, and when it runs out (epoch seconds). */
    private val live = mutableMapOf<String, Pair<String, Long>>()

    private val sockets = CopyOnWriteArrayList<Socket>()

    /** Every Phoenix frame Realtime got, in order. */
    val received = CopyOnWriteArrayList<JsonObject>()

    override val backend: Backend

    init {
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = answer(request)
        }
        web.start(InetAddress.getByName("127.0.0.1"), 0)
        backend = Backend(url = "http://127.0.0.1:${web.port}", kind = BackendKind.supabase)
    }

    override fun client(tokens: DeviceTokens): SupabaseServerClient = SupabaseServerClient(backend, tokens)

    /** The PocketTerm server behind it, out of reach from now on. */
    fun stopServer() = own.stopServer()

    override fun stop() {
        // A server-side socket has no call to cancel: it closes.
        for (s in sockets) runCatching { s.ws.close(1001, null) }
        web.close()
        own.stop()
    }

    /** Realtime closes [topic] on every connection joined to it (`phx_close`), as it does when it drops a channel. */
    fun closeChannel(topic: String) {
        for (s in sockets) {
            val joinRef = synchronized(lock) { s.joins.remove(topic) } ?: continue
            s.send(jsonOf("topic" to "realtime:$topic", "event" to "phx_close", "payload" to jsonOf(), "ref" to joinRef, "join_ref" to joinRef))
        }
    }

    /** How many connections are joined to [topic]. */
    fun joined(topic: String): Int = sockets.count { synchronized(lock) { topic in it.joins } }

    private fun answer(request: RecordedRequest): MockResponse {
        val path = request.url.encodedPath
        if (path == "/realtime/v1/websocket") {
            if (request.url.queryParameter("apikey") != APIKEY || request.url.queryParameter("vsn") != "1.0.0") {
                return reply(403, jsonOf("message" to "Invalid API key"))
            }
            return MockResponse.Builder().webSocketUpgrade(Socket()).build()
        }
        val prefix = "/functions/v1/pocketterm"
        if (!path.startsWith("$prefix/")) return reply(404, jsonOf("error" to "not_found", "message" to "No such endpoint."))
        val rest = path.removePrefix(prefix)
        val bearer = request.headers["authorization"]?.removePrefix("Bearer ")
        return when {
            rest == "/v1/setup/new" && request.method == "POST" -> {
                val me = me(bearer) ?: return forward(request, "/v1/me", "GET", null)
                if (me["device"].obj?.get("role").str != "desktop") {
                    return reply(403, jsonOf("error" to "forbidden", "message" to "Only a computer makes setup links."))
                }
                val setup = UUID.randomUUID().toString().replace("-", "")
                current = setup
                reply(200, jsonOf("setup" to setup))
            }
            rest == "/v1/setup/redeem" && request.method == "POST" -> {
                val body = jsonDecodeOrNull(request.body?.utf8() ?: "").obj ?: JsonObject(emptyMap())
                if (body["setup"].str != current) {
                    return reply(400, jsonOf("error" to "invalid_code", "message" to "That setup link doesn't work."))
                }
                val real = JsonObject(body + ("setup" to own.setupToken.toJsonElement()))
                forward(request, rest, "POST", jsonEncode(real).toByteArray())
            }
            rest == "/v1/live/token" && request.method == "POST" -> {
                me(bearer) ?: return forward(request, "/v1/me", "GET", null)
                val token = "live-" + UUID.randomUUID()
                val expires = System.currentTimeMillis() / 1000 + ttlSeconds
                synchronized(lock) { live[token] = bearer!! to expires }
                reply(200, jsonOf("token" to token, "expires" to expires, "apikey" to APIKEY))
            }
            rest == "/v1/ws" -> reply(404, jsonOf("error" to "not_found", "message" to "PocketTerm on Supabase has no WebSocket of its own."))
            else -> {
                val res = forward(request, rest, request.method ?: "GET", request.body?.toByteArray())
                val left = request.method == "DELETE" && rest.startsWith("/v1/devices/") || request.method == "POST" && rest == "/v1/erase"
                if (left && res.code < 400) tellLeft()
                res
            }
        }
    }

    /** GET /v1/me for [bearer] on the server behind; null when it isn't signed in. */
    private fun me(bearer: String?): JsonObject? {
        if (bearer == null) return null
        val req = Request.Builder().url("${own.backend.url}/v1/me").header("authorization", "Bearer $bearer").build()
        return http.newCall(req).execute().use { r -> if (r.code == 200) jsonDecodeOrNull(r.body.string()).obj else null }
    }

    private fun forward(request: RecordedRequest, path: String, method: String, body: ByteArray?): MockResponse {
        val content = when {
            body != null && body.isNotEmpty() -> body.toRequestBody(request.headers["content-type"]?.toMediaTypeOrNull())
            method == "POST" || method == "PUT" -> ByteArray(0).toRequestBody(null)
            else -> null
        }
        val req = Request.Builder().url("${own.backend.url}$path").method(method, content)
        request.headers["authorization"]?.let { req.header("authorization", it) }
        return http.newCall(req.build()).execute().use { r: Response ->
            val b = MockResponse.Builder().code(r.code).body(okio.Buffer().write(r.body.bytes()))
            r.header("content-type")?.let { b.setHeader("content-type", it) }
            b.build()
        }
    }

    private fun reply(status: Int, body: JsonObject): MockResponse =
        MockResponse.Builder().code(status).setHeader("content-type", "application/json").body(jsonEncode(body)).build()

    /** A device left: everyone on a computer's topic hears `pt.left`, and checks its own sign-in. */
    private fun tellLeft() {
        for (s in sockets) {
            for (topic in synchronized(lock) { s.joins.keys.toList() }) {
                s.send(broadcast(topic, "pt.left", jsonOf()))
            }
        }
    }

    private fun broadcast(topic: String, event: String, payload: JsonElement): JsonObject = jsonOf(
        "topic" to "realtime:$topic",
        "event" to "broadcast",
        "payload" to jsonOf("type" to "broadcast", "event" to event, "payload" to payload),
        "ref" to null,
    )

    /** Whether [token] is a live token, not run out, of a device still signed in. */
    private fun valid(token: String?): Boolean {
        val (bearer, expires) = synchronized(lock) { live[token] } ?: return false
        return expires > System.currentTimeMillis() / 1000 && me(bearer) != null
    }

    /** One Realtime connection. */
    private inner class Socket : WebSocketListener() {
        lateinit var ws: WebSocket

        /** Topics joined, and their join refs. */
        val joins = mutableMapOf<String, String>()

        fun send(frame: JsonObject) {
            ws.send(jsonEncode(frame))
        }

        private fun reply(topic: String, ref: String?, joinRef: String?, status: String, response: JsonObject) = send(
            jsonOf(
                "topic" to topic,
                "event" to "phx_reply",
                "payload" to jsonOf("status" to status, "response" to response),
                "ref" to ref,
                "join_ref" to joinRef,
            ),
        )

        override fun onOpen(webSocket: WebSocket, response: Response) {
            ws = webSocket
            sockets.add(this)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val m = jsonDecodeOrNull(text).obj ?: return
            received.add(m)
            val topic = m["topic"].str ?: return
            val t = topic.removePrefix("realtime:")
            val payload = m["payload"].obj ?: JsonObject(emptyMap())
            val ref = m["ref"].str
            val joinRef = m["join_ref"].str
            when (m["event"].str) {
                "heartbeat" -> if (topic == "phoenix") reply(topic, ref, null, "ok", jsonOf())
                "phx_join" -> {
                    val private = payload["config"].obj?.get("private").bool == true
                    if (private && valid(payload["access_token"].str)) {
                        synchronized(lock) { joins[t] = joinRef ?: "" }
                        reply(topic, ref, joinRef, "ok", jsonOf())
                    } else {
                        reply(topic, ref, joinRef, "error", jsonOf("reason" to "Unauthorized: you do not have permissions to read from this Channel topic: $t"))
                    }
                }
                "phx_leave" -> {
                    synchronized(lock) { joins.remove(t) }
                    reply(topic, ref, joinRef, "ok", jsonOf())
                }
                "access_token" -> if (!valid(payload["access_token"].str)) {
                    synchronized(lock) { joins.remove(t) }
                    send(jsonOf("topic" to topic, "event" to "system", "payload" to jsonOf("status" to "error", "message" to "Token has expired", "extension" to "system", "channel" to t), "ref" to null))
                }
                "broadcast" -> {
                    if (synchronized(lock) { t !in joins }) return
                    val event = payload["event"].str ?: return
                    // Not back to the sender: the client joins with broadcast.self false.
                    for (other in sockets) {
                        if (other !== this && synchronized(lock) { t in other.joins }) {
                            other.send(broadcast(t, event, payload["payload"] ?: JsonNull))
                        }
                    }
                }
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            sockets.remove(this)
            webSocket.close(1000, null)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            sockets.remove(this)
        }
    }

    companion object {
        const val APIKEY = "sb_publishable_test"

        /** A fake project in front of a new [OwnServer]. */
        fun start(): FakeSupabase = FakeSupabase(OwnServer.start())
    }
}
