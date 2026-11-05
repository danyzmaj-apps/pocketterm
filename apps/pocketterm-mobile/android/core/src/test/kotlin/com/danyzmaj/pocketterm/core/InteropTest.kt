package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import org.junit.After
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.time.Duration.Companion.seconds

/**
 * Talks to the real Dart server (apps/pocketterm-server), opt-in: `POCKETTERM_INTEROP=1`. A computer
 * signs in with the server's setup link, makes a pairing code, a phone redeems it, both join the
 * computer's topic and exchange sealed frames both ways, a sealed blob goes up and down, and both
 * sign out.
 */
class InteropTest {
    private lateinit var data: File
    private var server: Process? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val confined = executor.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + confined)

    @Before
    fun setUp() {
        assumeTrue("set POCKETTERM_INTEROP=1 to run against the Dart server", System.getenv("POCKETTERM_INTEROP") == "1")
        data = Files.createTempDirectory("pocketterm-interop").toFile()
    }

    @After
    fun tearDown() {
        scope.cancel()
        executor.shutdownNow()
        server?.let {
            // --exit-with-stdin: closing stdin stops it.
            it.outputStream.close()
            if (!it.waitFor(10, TimeUnit.SECONDS)) it.destroyForcibly()
        }
        if (::data.isInitialized) data.deleteRecursively()
    }

    private fun dart(vararg args: String): ProcessBuilder {
        val fvm = listOf("/opt/homebrew/bin/fvm", "fvm").firstOrNull { File(it).canExecute() } ?: "fvm"
        return ProcessBuilder(listOf(fvm, "dart", "run", "apps/pocketterm-server/bin/pocketterm_server.dart") + args)
            .directory(Vectors.repoRoot)
    }

    /** Starts the server on a free port; its port. */
    private fun startServer(): Int {
        val p = dart("serve", "--data", data.path, "--address", "127.0.0.1", "--port", "0", "--exit-with-stdin")
            .redirectError(ProcessBuilder.Redirect.INHERIT)
            .start()
        server = p
        val out = p.inputStream.bufferedReader()
        val deadline = System.currentTimeMillis() + 180_000
        while (System.currentTimeMillis() < deadline) {
            val line = out.readLine() ?: error("the server exited before listening")
            val j = jsonDecodeOrNull(line).obj ?: continue
            if (j["event"].str == "listening") {
                // Keep draining its stdout so it never blocks on a full pipe.
                Thread { out.forEachLine { } }.apply { isDaemon = true }.start()
                return j["port"].int!!
            }
        }
        error("no listening line in time")
    }

    private fun setupLink(port: Int): String {
        val p = dart("setup-link", "--data", data.path, "--public-url", "http://127.0.0.1:$port")
            .redirectError(ProcessBuilder.Redirect.INHERIT)
            .start()
        val text = p.inputStream.bufferedReader().readText().trim()
        check(p.waitFor(120, TimeUnit.SECONDS) && p.exitValue() == 0) { "setup-link failed: $text" }
        return text.lines().last { it.startsWith("pocketterm://") }
    }

    @Test
    fun `a computer and a phone pair, talk sealed both ways, pass a blob and sign out`() = runBlocking {
        val port = startServer()
        val link = setupLink(port)
        val backend = assertNotNull(Backend.fromLink(link))
        assertEquals("http://127.0.0.1:$port", backend.url)
        assertNull(backend.check(), "the server's health")
        val setup = assertNotNull(Backend.setupToken(link))

        // The computer signs in with the setup link, lists itself and makes a code.
        val computerTokens = MemoryDeviceTokens()
        val computer = Server(backend, computerTokens)
        val computerAccount = computer.redeemSetup(setup, label = "Interop Mac", platform = "macos")
        assertEquals(DeviceRole.desktop, computerAccount.device.role)
        val desktopId = "interop1"
        computer.putDesktop(desktopId, name = "Interop Mac", platform = "macos")
        val key = ChannelKey.generate()
        val pairing = backend.linkWithCode(computer.createPairingCode(), ComputerKey(desktopId, key))

        // The phone scans it: the code signs it in, the key is the computer's.
        val code = assertNotNull(Backend.pairingCode(pairing))
        assertEquals(ComputerKey(desktopId, key), Backend.computerKey(pairing))
        val phone = Server(backend, MemoryDeviceTokens())
        val phoneAccount = phone.redeemCode(code, label = "Interop Phone", platform = "android")
        assertEquals(DeviceRole.phone, phoneAccount.device.role)
        assertEquals(computerAccount.id, phoneAccount.id, "one server")
        val listed = phone.desktops().map { Desktop.fromJson(it) }
        assertEquals(listOf(desktopId), listed.map { it.id })
        assertEquals(true, listed.single().online)
        assertEquals(setOf("Interop Mac", "Interop Phone"), computer.devices().map { it.label }.toSet())

        // Both join the computer's topic; each hears the other's sealed messages.
        val toComputer = CompletableDeferred<JsonObject>()
        val toPhone = CompletableDeferred<JsonObject>()
        val computerJoined = CompletableDeferred<Unit>()
        val phoneJoined = CompletableDeferred<Unit>()
        val (computerChannel, phoneChannel) = withContext(confined) {
            val c = TerminalChannel(
                computer, desktopId, mapOf("hello" to { p: JsonObject -> toComputer.complete(p); Unit }),
                key = key, name = "interop computer", scope = scope,
                onJoined = { if (it) computerJoined.complete(Unit) },
            )
            val p = TerminalChannel(
                phone, desktopId, mapOf("state" to { m: JsonObject -> toPhone.complete(m); Unit }),
                key = key, name = "interop phone", scope = scope,
                onJoined = { if (it) phoneJoined.complete(Unit) },
            )
            c.open()
            p.open()
            c to p
        }
        withTimeout(30.seconds) {
            computerJoined.await()
            phoneJoined.await()
        }
        val hello = jsonOf("from" to "phone-1", "session" to "kitty-1/1", "text" to "héllo ✓")
        val state = jsonOf("sessions" to emptyList<Any>(), "home" to "/Users/me", "seq" to 7)
        withContext(confined) { phoneChannel.send("hello", hello) }
        assertEquals(hello, withTimeout(15.seconds) { toComputer.await() })
        withContext(confined) { computerChannel.send("state", state) }
        assertEquals(state, withTimeout(15.seconds) { toPhone.await() })

        // A sealed image goes up from the phone and comes down on the computer, once.
        val image = ByteArray(300_000) { (it * 31).toByte() }
        val path = phone.newBlobPath()
        assertEquals(true, Server.isBlobPath(path))
        phone.putBlob(path, sealBytes(key, image, imageAad(path)))
        val got = computer.getBlob(path)
        assertContentEquals(image, openBytes(key, got, imageAad(path)))
        assertNull(openBytes(key, got, imageAad("another")), "sealed for its own path")
        assertFailsWith<ServerException> { computer.getBlob(path) }

        withContext(confined) {
            computerChannel.close()
            phoneChannel.close()
        }

        // The phone signs out: its token stops working there and is gone here.
        phone.leave()
        assertNull(phone.account)
        val stale = Server(backend, MemoryDeviceTokens())
        assertFailsWith<ServerException> { stale.createPairingCode() }
        assertEquals(listOf("Interop Mac"), computer.devices().map { it.label })

        // The computer too; a sign-in kept from before is refused and ended.
        val kept = computerTokens.value
        computer.leave()
        assertNull(computerTokens.value)
        val again = Server(backend, MemoryDeviceTokens(kept))
        again.load()
        assertNotNull(again.account)
        val ended = CompletableDeferred<Unit>()
        val watch = scope.launch(start = CoroutineStart.UNDISPATCHED) { again.ended.collect { ended.complete(Unit) } }
        again.recheck()
        withTimeout(5.seconds) { ended.await() }
        watch.cancel()
        assertNull(again.account)
    }
}
