package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.junit.After
import org.junit.Before
import org.junit.Test
import java.net.InetAddress
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** A computer, or with [phone] a phone, keeping its sign-in in [tokens] and the computer keys from links in [keys]. */
private open class TestDevice(
    device: String,
    scope: CoroutineScope,
    val phone: Boolean = false,
    val atOnce: Boolean = false,
    val tokens: MemoryDeviceTokens = MemoryDeviceTokens(),
) : Session(device, scope) {
    val keys = mutableListOf<ComputerKey>()

    /** What a computer puts in its phone codes. */
    var computer: ComputerKey? = null

    /** The server kept for the next launch (Backend.save/load/clear). */
    var saved: Backend? = null

    /** What [notices] said, in order. */
    val told = mutableListOf<String>()

    override val role: DeviceRole get() = if (phone) DeviceRole.phone else DeviceRole.desktop
    override val platform: String get() = if (phone) "ios" else "macos"
    override val deviceTokens: DeviceTokens get() = tokens
    override val signInAtOnce: Boolean get() = atOnce
    override val hostsServer: Boolean get() = !phone

    override suspend fun loadBackend(): Backend? = saved
    override suspend fun saveBackend(backend: Backend) {
        saved = backend
    }

    override suspend fun clearBackend() {
        saved = null
    }

    override suspend fun addComputerKey(computer: ComputerKey) {
        keys.add(computer)
    }

    override fun computerKey(desktopId: String): ChannelKey? = keys.lastOrNull { it.desktop == desktopId }?.key
    override suspend fun pairingComputer(): ComputerKey? = computer
    override fun onNotice(message: String) {
        told.add(message)
    }

    override fun storageProblem(e: Throwable): String? = if (e is StorageLocked) STORAGE_PROBLEM else null

    companion object {
        const val STORAGE_PROBLEM = "PocketTerm can't use this phone's secure storage. Unlock it, then try again."
    }
}

/** What secure storage throws while it's locked or missing. */
private class StorageLocked : Exception("locked")

/** Storage that refuses until [locked] is turned off, as a locked or missing Keychain/Keystore does. */
private class LockedStorage : MemoryDeviceTokens() {
    @Volatile
    var locked = true

    override suspend fun write(value: String?) {
        if (locked) throw StorageLocked()
        super.write(value)
    }
}

/** A signed-out phone that records which setup links it acts on. */
private class LinkSession(scope: CoroutineScope) : TestDevice("iPhone", scope, phone = true) {
    val connected = mutableListOf<String>()
    val scans = mutableListOf<Boolean>()

    override suspend fun connectLink(link: String, scanned: Boolean) {
        connected.add(link)
        scans.add(scanned)
    }
}

class SessionTest : Confined() {
    private lateinit var own: OwnServer
    private lateinit var mac: TestDevice
    private val devices = mutableListOf<TestDevice>()

    private fun device(label: String, phone: Boolean = false, atOnce: Boolean = false, tokens: MemoryDeviceTokens = MemoryDeviceTokens()) =
        TestDevice(label, scope, phone = phone, atOnce = atOnce, tokens = tokens).also { devices.add(it) }

    @Before
    fun setUp() {
        own = OwnServer.start()
        mac = device("MacBook Pro").apply { computer = ComputerKey("abcd1234", ChannelKey.generate()) }
        test { mac.connectLink(own.setupLink) }
    }

    @After
    fun tearDown() {
        test { for (d in devices.reversed()) d.disconnect() }
        closeConfined()
        if (::own.isInitialized) own.stop()
    }

    @Test
    fun `a computer signs in with the server's setup link, a phone with its code, keeping the computer's key`() = test {
        assertNull(mac.authError)
        assertEquals(DeviceRole.desktop, mac.user?.device?.role)
        assertEquals("MacBook Pro", mac.user?.device?.label)

        val phone = device("iPhone", phone = true)
        phone.connectLink(mac.pairingLink(), scanned = true)
        assertNull(phone.authError)
        assertEquals(DeviceRole.phone, phone.user?.device?.role)
        assertEquals(mac.user?.id, phone.user?.id, "the same server")
        assertEquals(listOf(mac.computer), phone.keys)

        // A code works once.
        val link = mac.pairingLink()
        val second = device("iPad", phone = true)
        second.connectLink(link)
        assertNotNull(second.user)
        val third = device("Pixel", phone = true)
        third.connectLink(link)
        assertNull(third.user)
        assertTrue(third.authError!!.contains("used"))
    }

    // Dart: a Keychain that refuses (flutter_secure_storage's PlatformException); here any storage problem the app names.
    @Test
    fun `storage that refuses the sign-in says so plainly, and Try again signs in once it lets`() = test {
        val storage = LockedStorage()
        val other = TestDevice("Mac mini", scope, tokens = storage).also { devices.add(it) }
        other.connectLink(own.setupLink)
        assertNull(other.user)
        assertEquals(TestDevice.STORAGE_PROBLEM, other.authError)
        assertEquals(own.setupLink, other.retryLink)

        storage.locked = false
        other.retry()
        assertNull(other.authError)
        assertEquals("Mac mini", other.user?.device?.label)
        assertNull(other.retryLink)
    }

    @Test
    fun `a link not from the scanner signs a phone in but never gives it a computer's key`() = test {
        val phone = device("iPhone", phone = true)
        phone.connectLink(mac.pairingLink())
        assertNotNull(phone.user)
        assertTrue(phone.keys.isEmpty(), "signed out: the sign-in goes ahead, the key does not")

        val planted = ComputerKey("zzzz9999", ChannelKey.generate())
        val link = mac.backend!!.linkWithCode("ABCD-1234", computer = planted)
        phone.connectLink(link)
        assertTrue(phone.keys.isEmpty(), "signed in: still no key")
        assertTrue(phone.told.single().contains("scanner"))
        assertNull(phone.authError, "the signed-out pages say nothing of it later")

        phone.connectLink(link, scanned = true)
        assertEquals(listOf(planted), phone.keys)
    }

    @Test
    fun `a link without what this device signs in with says so, and a phone never takes a setup token`() = test {
        val phone = device("iPhone", phone = true)
        phone.connectLink(own.setupLink)
        assertNull(phone.user)
        assertTrue(phone.authError!!.contains("no sign-in code"))

        val other = device("Mac mini")
        other.connectLink(own.backend.linkWithCode(mac.server!!.createPairingCode()))
        assertNull(other.user)
        assertTrue(other.authError!!.contains("no setup token"))
    }

    @Test
    fun `a relaunch is signed in from what the device kept, signing out leaves the server for good`() = test {
        val tokens = MemoryDeviceTokens()
        val phone = device("iPhone", phone = true, tokens = tokens)
        phone.connectLink(mac.pairingLink())
        val id = phone.user!!.device.id

        val relaunched = device("iPhone", phone = true, tokens = tokens)
        relaunched.connect(own.backend)
        assertEquals(id, relaunched.user?.device?.id)

        relaunched.signOut()
        assertNull(relaunched.user)
        assertEquals("You signed out.", relaunched.signedOutReason)
        assertNull(tokens.value)
        assertFalse(mac.server!!.devices().map { it.id }.contains(id), "its token works no more")
    }

    @Test
    fun `a phone the computer signed out hears it the next time it asks, with the reason`() = test {
        val phone = device("iPhone", phone = true)
        phone.connectLink(mac.pairingLink())
        mac.server!!.revokeDevice(phone.user!!.device.id)

        try {
            phone.server!!.desktops()
            throw AssertionError("expected a ServerException")
        } catch (_: ServerException) {
        }
        pump()
        assertNull(phone.user)
        assertTrue(phone.signedOutReason!!.contains("Scan a new code"))

        // A relaunch with the token it kept before is signed out too.
        val kept = device("iPhone", phone = true, tokens = MemoryDeviceTokens(phone.tokens.value))
        kept.connect(own.backend)
        assertNull(kept.user)
    }

    @Test
    fun `a signed-in phone that scans another server's computer stays where it is and says how to switch`() = test {
        val phone = device("iPhone", phone = true)
        phone.connectLink(mac.pairingLink(), scanned = true)
        val before = phone.user
        val elsewhere = Backend(url = "https://other.example.com")
        val link = elsewhere.linkWithCode("ABCD-1234", computer = ComputerKey("zzzz9999", ChannelKey.generate()))
        phone.connectLink(link, scanned = true)
        assertSame(before, phone.user)
        assertEquals(own.backend, phone.backend)
        assertEquals(listOf(mac.computer), phone.keys, "that computer's key isn't taken")
        val told = phone.told.single()
        assertTrue(told.contains("other.example.com") && told.contains("Leave this server"), told)

        phone.signOut()
        assertNull(phone.authError)
    }

    @Test
    fun `a scanned code can't swap the key a phone holds for a computer unless its pairing code works`() = test {
        val phone = device("iPhone", phone = true)
        phone.connectLink(mac.pairingLink(), scanned = true)
        val devices = mac.server!!.devices().size

        // A QR anyone could make: this server, a real computer's id, their own key.
        val planted = ComputerKey(mac.computer!!.desktop, ChannelKey.generate())
        val link = mac.backend!!.linkWithCode("ABCD-EFGH-JKMN-PQRS-TVWX-YZ01-2345", computer = planted)
        phone.connectLink(link, scanned = true)
        assertEquals(mac.computer!!.key, phone.computerKey(planted.desktop), "the key it held stays")
        assertTrue(phone.told.single().contains("doesn't work"))

        // The computer reset its key: its new code carries the new one, and the phone takes it.
        mac.computer = ComputerKey(mac.computer!!.desktop, ChannelKey.generate())
        phone.connectLink(mac.pairingLink(), scanned = true)
        assertEquals(mac.computer!!.key, phone.computerKey(planted.desktop))
        assertEquals(1, phone.told.size)
        assertNotNull(phone.user, "still the same sign-in")
        assertEquals(devices, mac.server!!.devices().size, "the sign-in that tried the code left")
    }

    @Test
    fun `erasing the server leaves no sign-in problem behind for the setup page`() = test {
        mac.authError = "Sign out before switching to other.example.com."
        mac.eraseServer()
        assertNull(mac.user)
        assertNull(mac.authError)
    }

    @Test
    fun `signing out with the server out of reach still forgets the sign-in here`() = test {
        val tokens = MemoryDeviceTokens()
        val phone = device("iPhone", phone = true, tokens = tokens)
        phone.connectLink(mac.pairingLink())
        own.stopServer()
        phone.signOut()
        assertNull(phone.user)
        assertNull(tokens.value)
        assertEquals("You signed out.", phone.signedOutReason)
    }

    // A phone launched with the sign-in it kept.

    private fun kept(held: Held) = MemoryDeviceTokens(
        jsonEncode(
            jsonOf(
                "url" to held.backend.url,
                "token" to "token-1",
                "server" to "srv0000000000001",
                "device" to jsonOf("id" to "dev0000000000001", "role" to "phone", "label" to "iPhone", "platform" to "ios"),
            ),
        ),
    )

    private fun withHeld(body: suspend CoroutineScope.(Held, MemoryDeviceTokens) -> Unit) {
        val held = Held()
        try {
            test { body(held, kept(held)) }
        } finally {
            held.stop()
        }
    }

    @Test
    fun `a phone launched with the sign-in it kept is signed in before the server answers, and stays so when the answer is no sign-in answer`() =
        withHeld { held, kept ->
            val phone = device("iPhone", phone = true, atOnce = true, tokens = kept)
            withTimeout(2.seconds) { phone.connect(held.backend) }
            assertEquals("dev0000000000001", phone.user?.device?.id, "the server holds its answer")

            // A captive portal's page, say.
            held.answer(200, "<html>Sign in to the Wi-Fi</html>")
            assertNotNull(phone.user)
            assertNotNull(kept.value)
        }

    @Test
    fun `a phone launched with the sign-in it kept is signed out, with the reason, once the server refuses what it kept`() =
        withHeld { held, kept ->
            val phone = device("iPhone", phone = true, atOnce = true, tokens = kept)
            withTimeout(2.seconds) { phone.connect(held.backend) }
            assertNotNull(phone.user)

            held.answer(401, jsonEncode(jsonOf("error" to "unauthorized", "message" to "Sign in again.")))
            pump()
            assertNull(phone.user)
            assertTrue(phone.signedOutReason!!.contains("Scan a new code"))
            assertNull(kept.value)
        }

    @Test
    fun `a phone launched with the sign-in it kept, signed out while the server is asked - the answer that comes after doesn't sign it back in`() =
        withHeld { held, kept ->
            val phone = device("iPhone", phone = true, atOnce = true, tokens = kept)
            withTimeout(2.seconds) { phone.connect(held.backend) }
            phone.signOut()
            held.answer(200, jsonEncode(Held.me))
            pump()
            assertNull(phone.user)
            assertNull(kept.value, "the sign-in it left isn't kept again")
            assertNull(phone.server!!.account)
        }

    // A setup link opened from outside the app.

    private val mine = Backend(url = "https://mine.example.com")
    private val theirs = Backend(url = "https://theirs.example.com")

    @Test
    fun `a setup link opened from outside the app connects a signed-out device to another server only once the person says so`() = test {
        val session = LinkSession(scope)
        val link = theirs.linkWithCode("ABCD-1234")
        session.openedLink(link, mine)
        assertTrue(session.connected.isEmpty())
        assertEquals(link, session.linkToConfirm)
        session.answerLink(connect = true)
        assertEquals(listOf(link), session.connected)
        assertNull(session.linkToConfirm)
    }

    @Test
    fun `a setup link opened from outside the app is dropped when the person says no, and asks on a device set up nowhere yet`() = test {
        val session = LinkSession(scope)
        session.openedLink(theirs.linkWithCode("ABCD-1234"), null)
        assertNotNull(session.linkToConfirm)
        session.answerLink(connect = false)
        assertTrue(session.connected.isEmpty())
        assertNull(session.linkToConfirm)
    }

    @Test
    fun `a setup link opened from outside the app goes ahead for the device's own server, never as a scan`() = test {
        val session = LinkSession(scope)
        val link = mine.linkWithCode("ABCD-1234")
        session.openedLink(link, mine)
        assertEquals(listOf(link), session.connected)
        assertEquals(listOf(false), session.scans)
        assertNull(session.linkToConfirm)
    }

    @Test
    fun `on Supabase, a computer signs in with the project's setup link and a phone with its code, both keep the kind`() = test {
        val project = FakeSupabase.start()
        try {
            val studio = device("Mac Studio").apply { computer = ComputerKey("efgh5678", ChannelKey.generate()) }
            studio.connectLink(project.backend.linkWithSetup(project.setupToken))
            assertNull(studio.authError)
            assertIs<SupabaseServerClient>(studio.server)
            assertEquals(project.backend, studio.saved)

            val phone = device("iPhone", phone = true)
            val code = studio.pairingLink()
            assertEquals(project.backend, Backend.fromLink(code), "the computer's code names the Supabase project")
            phone.connectLink(code, scanned = true)
            assertNull(phone.authError)
            assertEquals(studio.user?.id, phone.user?.id)
            assertEquals(listOf(studio.computer), phone.keys)
            phone.disconnect()
            studio.disconnect()
        } finally {
            project.stop()
        }
    }
}

/** A server that holds GET /v1/me until [answer] says what to answer it, then answers it at once; anything else gets `{}` at once. */
private class Held {
    private val web = MockWebServer()
    private val lock = Object()
    private var answer: Pair<Int, String>? = null
    private var waiting = 0

    init {
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.url.encodedPath != "/v1/me") return MockResponse.Builder().code(200).body("{}").build()
                val a = synchronized(lock) {
                    waiting++
                    val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
                    while (answer == null && System.nanoTime() < end) lock.wait(50)
                    waiting--
                    answer ?: (503 to "")
                }
                return MockResponse.Builder().code(a.first).body(a.second).build()
            }
        }
        web.start(InetAddress.getByName("127.0.0.1"), 0)
    }

    val backend = Backend(url = "http://127.0.0.1:${web.port}")

    /** Answers, once the GET /v1/me is there, with [status] and [body]. */
    suspend fun answer(status: Int, body: String) {
        for (i in 0 until 100) {
            if (synchronized(lock) { waiting > 0 }) break
            delay(20)
        }
        synchronized(lock) {
            answer = status to body
            lock.notifyAll()
        }
        // Each answer read before going on.
        delay(100)
    }

    fun stop() {
        synchronized(lock) {
            if (answer == null) answer = 503 to ""
            lock.notifyAll()
        }
        web.close()
    }

    companion object {
        val me = jsonOf(
            "device" to jsonOf("id" to "dev0000000000001", "role" to "phone", "label" to "iPhone", "platform" to "ios"),
            "server" to jsonOf("id" to "srv0000000000001"),
        )
    }
}

