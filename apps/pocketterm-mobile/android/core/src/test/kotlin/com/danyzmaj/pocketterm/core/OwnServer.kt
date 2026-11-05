package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonObject
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.junit.Assume.assumeTrue
import java.io.File
import java.net.InetAddress
import java.nio.file.Files
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

/** A server the client tests run against: the PocketTerm server ([OwnServer]) or PocketTerm on a Supabase project ([FakeSupabase]). */
interface TestBackend {
    val backend: Backend

    /** A computer's setup token for it. */
    val setupToken: String

    /** What it sent the push relay, in order (sealed to the relay's key). */
    val relayed: MutableList<JsonObject>

    /** A client for it signed in as nobody yet. */
    fun client(tokens: DeviceTokens = MemoryDeviceTokens()): Server

    /** A computer signed in with the setup token. */
    suspend fun desktop(label: String = "MacBook Pro"): Server {
        val c = client()
        c.redeemSetup(setupToken, label = label, platform = "macos")
        return c
    }

    /** A phone signed in with a code from [desktop]. */
    suspend fun phone(desktop: Server, label: String = "iPhone"): Server {
        val c = client()
        c.redeemCode(desktop.createPairingCode(), label = label, platform = "ios")
        return c
    }

    fun stop()
}

/**
 * The real PocketTerm server (packages/pocketterm_server, compiled once per test run from
 * apps/pocketterm-server with `fvm dart compile exe`) on loopback, in a temporary data directory,
 * with a push relay that records what reaches it ([relayed]). Tests using it are skipped where
 * there's no Dart SDK (fvm).
 */
class OwnServer private constructor(
    private val dir: File,
    private val relay: MockWebServer,
    private val process: Process,
    port: Int,
    override val setupToken: String,
    override val relayed: MutableList<JsonObject>,
) : TestBackend {

    override val backend = Backend(url = "http://127.0.0.1:$port")

    /** The link a computer opens to sign in, pointing at this server's port. */
    val setupLink: String get() = backend.linkWithSetup(setupToken)

    override fun client(tokens: DeviceTokens): Server = PocketTermServerClient(backend, tokens)

    /** Stops the server only: it's out of reach from now on. */
    fun stopServer() {
        if (!process.isAlive) return
        // --exit-with-stdin: closing stdin stops it.
        runCatching { process.outputStream.close() }
        if (!process.waitFor(10, TimeUnit.SECONDS)) process.destroyForcibly().waitFor()
    }

    override fun stop() {
        stopServer()
        relay.close()
        dir.deleteRecursively()
    }

    companion object {
        private val binary: File? by lazy {
            val fvm = listOf("/opt/homebrew/bin/fvm", "/usr/local/bin/fvm").firstOrNull { File(it).canExecute() }
                ?: System.getenv("PATH").orEmpty().split(File.pathSeparator).map { File(it, "fvm") }.firstOrNull { it.canExecute() }?.path
                ?: return@lazy null
            val out = File(Vectors.repoRoot, "apps/pocketterm-mobile/android/core/build/test-server/pocketterm-server")
            out.parentFile.mkdirs()
            val p = ProcessBuilder(fvm, "dart", "compile", "exe", "apps/pocketterm-server/bin/pocketterm_server.dart", "-o", out.path)
                .directory(Vectors.repoRoot)
                .redirectErrorStream(true)
                .start()
            val log = p.inputStream.bufferedReader().readText()
            check(p.waitFor(300, TimeUnit.SECONDS) && p.exitValue() == 0) { "the server didn't compile:\n$log" }
            out
        }

        fun start(): OwnServer {
            val bin = binary
            assumeTrue("the PocketTerm server needs the Dart SDK (fvm)", bin != null)
            val dir = Files.createTempDirectory("pocketterm_core_server").toFile()
            val relayed = CopyOnWriteArrayList<JsonObject>()
            val relay = MockWebServer()
            relay.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    jsonDecodeOrNull(request.body?.utf8() ?: "").obj?.let { relayed.add(it) }
                    return MockResponse.Builder().code(200).build()
                }
            }
            relay.start(InetAddress.getByName("127.0.0.1"), 0)
            val p = ProcessBuilder(
                bin!!.path, "serve", "--data", dir.path, "--address", "127.0.0.1", "--port", "0",
                "--relay", "http://127.0.0.1:${relay.port}/relay", "--exit-with-stdin",
            ).start()
            // The first start prints its setup link to stderr.
            val link = CompletableFuture<String>()
            Thread {
                p.errorStream.bufferedReader().forEachLine { line ->
                    if (line.startsWith("pocketterm://")) link.complete(line.trim())
                }
                link.completeExceptionally(IllegalStateException("the server printed no setup link"))
            }.apply { isDaemon = true }.start()
            val out = p.inputStream.bufferedReader()
            var port: Int? = null
            while (port == null) {
                val line = out.readLine() ?: error("the server exited before listening")
                val j = jsonDecodeOrNull(line).obj ?: continue
                if (j["event"].str == "listening") port = j["port"].int
            }
            Thread { out.forEachLine { } }.apply { isDaemon = true }.start()
            val setup = Backend.setupToken(link.get(30, TimeUnit.SECONDS)) ?: error("a setup link without a token")
            return OwnServer(dir, relay, p, port, setup, relayed)
        }
    }
}
