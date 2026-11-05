package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.time.Duration.Companion.seconds

/** What a device is to its server. */
enum class DeviceRole { desktop, phone }

/** A computer or phone signed in to the server (packages/pocketterm_server/PROTOCOL.md, Device). */
data class Device(
    /** 16 characters, made by the server. */
    val id: String,
    val role: DeviceRole,
    val label: String,
    /** `macos`, `windows`, `linux`, `ios` or `android`. */
    val platform: String,
    val seenAt: Instant? = null,
    /** It's the device asking (GET /v1/devices). */
    val current: Boolean = false,
) {
    fun toJson(): JsonObject = jsonOf("id" to id, "role" to role.name, "label" to label, "platform" to platform)

    companion object {
        fun fromJson(j: JsonObject): Device = Device(
            id = j["id"].str ?: throw IllegalArgumentException("a device without an id"),
            role = if (j["role"].str == "phone") DeviceRole.phone else DeviceRole.desktop,
            label = j["label"].str ?: "",
            platform = j["platform"].str ?: "",
            seenAt = parseDartDateTime(j["seen_at"].str ?: ""),
            current = j["current"].bool == true,
        )
    }
}

/** This device, signed in to its server: what's kept per server is keyed on [id], the server's own id, which never changes. */
data class Account(
    /** The server's id (GET /v1/me). */
    val id: String,
    /** This device, as the server knows it. */
    val device: Device,
)

/** Where a device keeps its sign-in (the device token and what came with it, one string): the phone's own secure storage ([Native.deviceToken]). */
interface DeviceTokens {
    suspend fun read(): String?

    /** Null forgets it. */
    suspend fun write(value: String?)
}

/** A sign-in that lasts as long as the app runs (tests). */
open class MemoryDeviceTokens(@Volatile var value: String? = null) : DeviceTokens {
    override suspend fun read(): String? = value

    override suspend fun write(value: String?) {
        this.value = value
    }
}

/** What the server answered instead (`{error, message}`), or that it couldn't be reached ([status] 0). [message] is worded for the person. */
class ServerException(
    val status: Int,
    /** The server's `error` (`invalid_code`, `unauthorized`, …; `offline`). */
    val code: String,
    override val message: String,
) : Exception(message) {
    override fun toString(): String = message
}

/**
 * The live channel's connection, in the frames of PROTOCOL.md's WebSocket (`join`, `send`,
 * `leave`, `ping` out; `joined`, `msg`, `pong`, `error` in), whatever carries them: the PocketTerm
 * server's own WebSocket, or Supabase Realtime ([RealtimeLive]). [closeCode] 4003 once closed:
 * this device was signed out.
 */
interface LiveSocket {
    /** Each frame as it comes, for one collector; completes when the connection is done. */
    val frames: Flow<String>

    fun add(frame: String)

    val closeCode: Int?

    suspend fun close(code: Int = 1000)
}

/**
 * Where this device is signed in (packages/pocketterm_server/PROTOCOL.md): signing in, pairing,
 * the computers list, images and push, and the live channel ([connectLive]). [Server.invoke]
 * picks the implementation for the backend's kind: [PocketTermServerClient] or [SupabaseServerClient].
 */
interface Server {
    val backend: Backend

    /** This device, signed in; null while signed out. */
    val account: Account?

    /** The server refused this device's token: it's signed out here now. */
    val ended: SharedFlow<Unit>

    /** Back at the front: the next requests go on new connections. */
    fun freshConnections()

    /** Reads the sign-in this device kept for this server, without asking it. */
    suspend fun load()

    /** Asks the server whether the sign-in still holds; a refusal ends it. */
    suspend fun recheck()

    /** Signs this computer in with the server's setup token (its setup link). */
    suspend fun redeemSetup(setup: String, label: String, platform: String): Account

    /** Signs this phone in with a computer's pairing code (its QR). */
    suspend fun redeemCode(code: String, label: String, platform: String): Account

    /** Leaves the server: the token stops working there and is forgotten here. */
    suspend fun leave()

    /** Computer only: wipes everything on the server, this device's sign-in too. Its setup link and id stay. */
    suspend fun erase()

    /** The server refused the token: forgotten here, [ended] says so. */
    suspend fun refused()

    /** Computer only: a pairing code for a phone, good once for 10 minutes. */
    suspend fun createPairingCode(): String

    /** Every computer and phone signed in to the server, oldest first. */
    suspend fun devices(): List<Device>

    /** Computer only: signs device [id] out. */
    suspend fun revokeDevice(id: String)

    /** The computers phones list, most recently seen first. */
    suspend fun desktops(): List<JsonObject>

    /** Computer only: lists computer [id] (also stamps it seen now). */
    suspend fun putDesktop(id: String, name: String, platform: String)

    suspend fun deleteDesktop(id: String)

    /** A new path for an image or file: the phone seals it for this path first. */
    fun newBlobPath(): String

    suspend fun putBlob(path: String, bytes: ByteArray)

    /** The blob at [path]; the server deletes it once sent. */
    suspend fun getBlob(path: String): ByteArray

    suspend fun deleteBlob(path: String)

    /** Push [action] with its [body]; the server's answer. */
    suspend fun push(action: String, body: JsonObject): JsonObject

    /** The live channel, signed in as this device. */
    suspend fun connectLive(): LiveSocket

    fun close()

    companion object {
        /** The client for [backend]'s kind, keeping its sign-in in [tokens]. */
        operator fun invoke(backend: Backend, tokens: DeviceTokens): Server = when (backend.kind) {
            BackendKind.pocketterm -> PocketTermServerClient(backend, tokens)
            BackendKind.supabase -> SupabaseServerClient(backend, tokens)
        }

        private val BLOB_PATH = Regex("^[A-Za-z0-9-]{1,64}$")

        /** [path] can be one of [newBlobPath]'s. */
        fun isBlobPath(path: String): Boolean = BLOB_PATH.matches(path)

        /** The most a blob may hold (the server's limit, 20 MiB). */
        const val maxBlobBytes: Int = 20 * 1024 * 1024
    }
}

/**
 * The PocketTerm server (packages/pocketterm_server/PROTOCOL.md) through this device's token:
 * signing in, pairing, the computers list, images and push. Signed in is having a token
 * ([account]); once the server refuses it (the device was revoked or left, the server was
 * erased) it is forgotten and [ended] says so. The live channel is TerminalChannel.kt.
 */
open class PocketTermServerClient(
    final override val backend: Backend,
    /** Where this device's sign-in is kept. */
    val tokens: DeviceTokens,
) : Server {
    @Volatile
    private var http: OkHttpClient = newHttp()

    /**
     * Back at the front: the next requests go on new connections. The ones kept open from before
     * may be dead without having said so (the system stops an app's network in the background,
     * the phone changed networks), and a request on one would wait out its whole timeout.
     * Requests under way finish where they are.
     */
    override fun freshConnections() {
        val old = http
        http = newHttp()
        old.connectionPool.evictAll()
    }

    @Volatile
    private var _account: Account? = null

    @Volatile
    private var token: String? = null

    /** The sign-in as kept in [tokens], so an unchanged one isn't written again. */
    @Volatile
    private var kept: String? = null

    override val account: Account? get() = _account

    private val _ended = MutableSharedFlow<Unit>(extraBufferCapacity = 8)

    @Volatile
    private var closed = false

    override val ended: SharedFlow<Unit> = _ended.asSharedFlow()

    /**
     * Reads the sign-in this device kept for this server: [account] at once, without asking the
     * server ([recheck] does), so a launch shows what it had before the network answers.
     */
    override suspend fun load() {
        try {
            val raw = tokens.read()
            val saved = jsonDecode(raw ?: "null").obj ?: return
            val url = saved["url"].str
            val t = saved["token"].str
            val server = saved["server"].str
            val device = saved["device"].obj
            if (url != null && t != null && server != null && device != null && url == backend.url) {
                token = t
                _account = Account(server, Device.fromJson(device))
                kept = raw
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: sign-in not read: $e")
        }
    }

    /**
     * Asks the server whether the sign-in still holds, and keeps what it says of this device. A
     * refusal ends it ([ended]); no answer (offline), or one this app doesn't read (a captive
     * portal's page), keeps it.
     */
    override suspend fun recheck() {
        val t = token ?: return
        try {
            val me = json("GET", "/v1/me", token = t)
            // Signed out, or in anew, meanwhile: the answer is about a sign-in that's gone.
            if (token == t) keep(t, me)
        } catch (e: ServerException) {
            if (e.status == 401 && token == t) refused()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: sign-in not checked: $e")
        }
    }

    override suspend fun redeemSetup(setup: String, label: String, platform: String): Account =
        redeem("/v1/setup/redeem", jsonOf("setup" to setup, "label" to label, "platform" to platform))

    override suspend fun redeemCode(code: String, label: String, platform: String): Account =
        redeem("/v1/pair/redeem", jsonOf("code" to code, "label" to label, "platform" to platform))

    private suspend fun redeem(path: String, body: JsonObject): Account {
        val answer = json("POST", path, body = body, auth = false)
        val t = answer.obj?.get("token").str ?: throw ServerException(500, "internal", "The server didn't send a sign-in.")
        return signedIn(t)
    }

    /** Asks the server who [token] is and keeps it. */
    private suspend fun signedIn(token: String): Account = keep(token, json("GET", "/v1/me", token = token))

    /** [token] and the device the server's GET /v1/me ([me]) says it is. */
    private suspend fun keep(token: String, me: JsonElement?): Account {
        val device = me.obj?.get("device").obj
        val server = me.obj?.get("server").obj?.get("id").str
        if (device == null || server == null) {
            throw ServerException(500, "internal", "The server sent an answer this app doesn't read.")
        }
        val account = Account(server, Device.fromJson(device))
        val k = jsonEncode(jsonOf("url" to backend.url, "token" to token, "server" to server, "device" to account.device.toJson()))
        if (k != kept) tokens.write(k)
        kept = k
        this.token = token
        _account = account
        return account
    }

    /**
     * Leaves the server: the token stops working there (DELETE /v1/devices/me) and is forgotten
     * here, also when the server can't be reached.
     */
    override suspend fun leave() {
        try {
            if (token != null) json("DELETE", "/v1/devices/me")
        } finally {
            withContext(kotlinx.coroutines.NonCancellable) { forget() }
        }
    }

    /**
     * Computer only: wipes everything on the server (every device, this one too, the computers
     * list, codes, push tokens, images). Its setup link and id stay.
     */
    override suspend fun erase() {
        json("POST", "/v1/erase")
        forget()
    }

    private suspend fun forget() {
        token = null
        _account = null
        kept = null
        tokens.write(null)
    }

    /**
     * The server refused the token (an answer 401, the live channel closed with 4003): forgotten
     * here, [ended] says so (unless [close]d by then).
     */
    override suspend fun refused() {
        if (token == null) return
        forget()
        if (!closed) _ended.emit(Unit)
    }

    override suspend fun createPairingCode(): String =
        json("POST", "/v1/pair").obj?.get("code").str ?: throw ServerException(500, "internal", "The server didn't send a code.")

    override suspend fun devices(): List<Device> =
        (json("GET", "/v1/devices") as JsonArray).map { Device.fromJson(it as JsonObject) }

    /** Computer only: signs device [id] out (a lost phone); it's told so the next time it asks. */
    override suspend fun revokeDevice(id: String) {
        json("DELETE", "/v1/devices/$id")
    }

    override suspend fun desktops(): List<JsonObject> = (json("GET", "/v1/desktops") as JsonArray).map { it as JsonObject }

    override suspend fun putDesktop(id: String, name: String, platform: String) {
        json("PUT", "/v1/desktops/$id", body = jsonOf("name" to name, "platform" to platform))
    }

    override suspend fun deleteDesktop(id: String) {
        json("DELETE", "/v1/desktops/$id")
    }

    override fun newBlobPath(): String = UUID.randomUUID().toString()

    /**
     * Uploads [bytes] to [path]. One over [Server.maxBlobBytes] fails here, with the reason: sent,
     * the server would cut it off and the reason would be lost.
     */
    override suspend fun putBlob(path: String, bytes: ByteArray) {
        if (bytes.size > Server.maxBlobBytes) {
            throw ServerException(413, "too_large", "That file is too large: the most is 20 MB.")
        }
        json("PUT", "/v1/blobs/$path", bytes = bytes)
    }

    override suspend fun getBlob(path: String): ByteArray = send("GET", "/v1/blobs/$path").second

    override suspend fun deleteBlob(path: String) {
        json("DELETE", "/v1/blobs/$path")
    }

    /**
     * Push [action] (register, unregister, notify, activity_register, activity_end, activity) with
     * its [body]; the server's answer (`{sent}` for notify and activity).
     */
    override suspend fun push(action: String, body: JsonObject): JsonObject =
        json("POST", "/v1/push/$action", body = body) as JsonObject

    /** The server's WebSocket (GET /v1/ws), signed in as this device. */
    override suspend fun connectLive(): LiveSocket {
        val t = token ?: throw ServerException(401, "unauthorized", "Not signed in.")
        return OkHttpLiveSocket.connect(http, wsUrl(backend.api) + "/v1/ws", mapOf("authorization" to "Bearer $t"))
    }

    override fun close() {
        closed = true
        http.connectionPool.evictAll()
    }

    /** A JSON request to [path] as this device, for what a subclass adds ([SupabaseServerClient]); a 401 ends the sign-in as any other. */
    protected suspend fun request(method: String, path: String, body: JsonObject? = null): JsonElement? = json(method, path, body = body)

    private suspend fun json(
        method: String,
        path: String,
        body: JsonObject? = null,
        bytes: ByteArray? = null,
        auth: Boolean = true,
        token: String? = null,
    ): JsonElement? {
        val res = send(method, path, body, bytes, auth, token).second
        return if (res.isEmpty()) null else jsonDecode(res.toString(Charsets.UTF_8))
    }

    private suspend fun send(
        method: String,
        path: String,
        body: JsonObject? = null,
        bytes: ByteArray? = null,
        auth: Boolean = true,
        token: String? = null,
    ): Pair<Int, ByteArray> {
        val bearer = token ?: this.token
        if (auth && bearer == null) throw ServerException(401, "unauthorized", "Not signed in.")
        val res: Pair<Int, ByteArray>
        try {
            val content = when {
                bytes != null -> bytes.toRequestBody(BINARY)
                body != null -> jsonEncode(body).toRequestBody(JSON)
                // OkHttp wants a body on these methods; the Dart client sent an empty one.
                method == "POST" || method == "PUT" -> ByteArray(0).toRequestBody(null)
                else -> null
            }
            val req = Request.Builder().url("${backend.api}$path").method(method, content)
            if (auth) req.header("authorization", "Bearer $bearer")
            res = http.newCall(req.build()).await().use { r: Response ->
                r.code to withContext(Dispatchers.IO) { r.body.bytes() }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: $method $path: $e")
            throw ServerException(0, "offline", backend.unreachable)
        }
        if (res.first < 400) return res
        var code = "internal"
        var message = "The server failed (${res.first})."
        // Not the server's own answer (a proxy's error page) keeps those.
        val answer = utf8DecodeOrNull(res.second)?.let { jsonDecodeOrNull(it) }.obj
        val c = answer?.get("error").str
        val m = answer?.get("message").str
        if (c != null && m != null) {
            code = c
            message = m
        }
        // The token this device holds stopped working.
        if (res.first == 401 && auth && token == null) refused()
        throw ServerException(res.first, code, message)
    }

    private companion object {
        val JSON = "application/json; charset=utf-8".toMediaType()
        val BINARY = "application/octet-stream".toMediaType()

        // A new connection pool; the timeouts the Dart client had (20 s per step).
        fun newHttp(): OkHttpClient = Http.base.newBuilder()
            .connectionPool(okhttp3.ConnectionPool())
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .writeTimeout(20, TimeUnit.SECONDS)
            .build()
    }
}

/** [url]'s http(s) scheme as ws(s). */
internal fun wsUrl(url: String): String = when {
    url.startsWith("https://") -> "wss://" + url.removePrefix("https://")
    url.startsWith("http://") -> "ws://" + url.removePrefix("http://")
    else -> url
}

/** An OkHttp WebSocket as a [LiveSocket]: its text frames as they are. */
internal class OkHttpLiveSocket private constructor() : LiveSocket, WebSocketListener() {
    private val incoming = Channel<String>(Channel.UNLIMITED)
    private val opened = CompletableDeferred<Unit>()
    private lateinit var ws: WebSocket

    @Volatile
    private var code: Int? = null

    override val frames: Flow<String> = incoming.receiveAsFlow()

    override val closeCode: Int? get() = code

    override fun add(frame: String) {
        ws.send(frame)
    }

    override suspend fun close(code: Int) {
        ws.close(code, null)
        incoming.close()
    }

    override fun onOpen(webSocket: WebSocket, response: Response) {
        opened.complete(Unit)
    }

    override fun onMessage(webSocket: WebSocket, text: String) {
        incoming.trySend(text)
    }

    override fun onMessage(webSocket: WebSocket, bytes: ByteString) {}

    override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
        this.code = code
        webSocket.close(code, null)
        incoming.close()
    }

    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
        if (this.code == null) this.code = code
        incoming.close()
    }

    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
        opened.completeExceptionally(t)
        incoming.close()
    }

    companion object {
        /** Connects to [url]; fails after 20 s without an answer. */
        suspend fun connect(http: OkHttpClient, url: String, headers: Map<String, String> = emptyMap()): OkHttpLiveSocket {
            val live = OkHttpLiveSocket()
            val req = Request.Builder().url(url).apply { headers.forEach { (k, v) -> header(k, v) } }.build()
            live.ws = http.newWebSocket(req, live)
            try {
                // A timeout is a failure to connect, not a cancellation of the caller.
                withTimeoutOrNull(20.seconds) { live.opened.await() }
                    ?: throw java.net.SocketTimeoutException("No answer from $url in 20 s")
            } catch (e: Throwable) {
                live.ws.cancel()
                throw e
            }
            return live
        }
    }
}
