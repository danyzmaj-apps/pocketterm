package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch

/**
 * The connected server ([Backend]) and signing in to it (a computer's code on a phone): what the
 * phone's app state builds on. Signed in is holding a device token ([Server.account]), kept in
 * [deviceTokens].
 *
 * Confined to [scope]: call it on the scope's (single-threaded) dispatcher, Main on Android.
 */
abstract class Session(
    /** This machine's name: its label on the server and of its push registration. */
    val device: String,
    protected val scope: CoroutineScope,
) : ChangeNotifier() {
    /**
     * What this device is to the server: a computer, unless a phone says so. A computer signs in
     * with the server's setup token, a phone only with a computer's pairing code.
     */
    open val role: DeviceRole get() = DeviceRole.desktop

    /** This device's platform, as the server takes it: `macos`, `windows`, `linux`, `ios` or `android`. */
    open val platform: String get() = "android"

    /** Where this device keeps its sign-in: the phone's own secure storage ([NativeDeviceTokens]). */
    protected abstract val deviceTokens: DeviceTokens

    /** The server saved at the last [connect] (where the platform side reads it too: [Backend.load]); null: none. */
    protected abstract suspend fun loadBackend(): Backend?

    /** Remembers [backend] for the next launch ([Backend.save]). */
    protected abstract suspend fun saveBackend(backend: Backend)

    /** Forgets the saved server ([Backend.clear]). */
    protected abstract suspend fun clearBackend()

    /** The server this device connects through; null until one is set up (the setup screen shows then). */
    var backend: Backend? = null
        private set

    /** Only while [backend] is set. */
    var server: Server? = null
        private set

    /** This device, signed in; null while signed out. */
    var user: Account? = null
        private set

    private var ended: Job? = null

    /** Why the last sign-in or connect didn't happen, for the signed-out pages; null once one did, and after signing out. */
    var authError: String? = null

    private val _notices = MutableSharedFlow<String>(extraBufferCapacity = 16)

    /**
     * What a link says to this device while it's signed in, once: one it can't use as is (a code
     * for another server, a computer's key that wasn't scanned, a code that didn't work). The page
     * in front shows it; [authError] stays the signed-out pages'.
     */
    val notices: SharedFlow<String> = _notices.asSharedFlow()

    private fun notice(message: String) {
        _notices.tryEmit(message)
        onNotice(message)
    }

    /** A notice went out ([notices]). */
    protected open fun onNotice(message: String) {}

    /** The key this device holds for [desktopId], if any (a phone's, from a scanned code). */
    open fun computerKey(desktopId: String): ChannelKey? = null

    /** The link whose sign-in failed only because the device couldn't keep it ([storageProblem]): [retry] tries it again. */
    var retryLink: String? = null

    /**
     * What a sign-in says when this device's secure storage didn't let PocketTerm keep it (the
     * Flutter app's Keychain case); null for any other failure.
     */
    protected open fun storageProblem(e: Throwable): String? = null

    /** Signs in again with [retryLink]. */
    suspend fun retry() {
        val link = retryLink
        if (link != null) connectLink(link)
    }

    /** Why the last sign-in is gone, once it is (signed out here, the server ended it); null after a sign-in. The phone shows it on its scan screen. */
    var signedOutReason: String? = null
        private set

    /** Set by [signOut] and [eraseServer] just before the sign-in goes. */
    private var leaving: String? = null

    private var links: Job? = null

    /**
     * Launch: opens the server this device was set up with, if any, and listens for setup links
     * (`pocketterm://setup?url=…[&code=…|&setup=…]`) opened from outside the app ([links]).
     */
    suspend fun start(links: Flow<String>? = null) {
        val saved = scope.async { loadBackend() }
        if (links != null) this.links = scope.launch { links.collect { openedLink(it, saved.await()) } }
        val b = saved.await()
        if (b != null) connect(b)
    }

    /**
     * A setup link opened from outside the app (a web page, a message, the camera app). One that
     * would connect this signed-out device to a server other than its own ([saved] until
     * [connect] is done) waits for the person ([linkToConfirm]): anyone can send a link, and this
     * device's sessions would then go through that server. Any other link goes to [onOtherLink].
     */
    fun openedLink(link: String, saved: Backend?) {
        val b = Backend.fromLink(link) ?: return onOtherLink(link)
        if (user == null && b != (backend ?: saved)) {
            linkToConfirm = link
            notifyListeners()
            onLinkToConfirm()
            return
        }
        // As Dart's unawaited call: it runs at once, up to its first suspension.
        scope.launch(start = CoroutineStart.UNDISPATCHED) { connectLink(link) }
    }

    /** A setup link to another server, waiting for [answerLink]. */
    var linkToConfirm: String? = null
        private set

    /** The person's answer to [linkToConfirm]: [connect] goes on with it. */
    suspend fun answerLink(connect: Boolean) {
        val link = linkToConfirm
        linkToConfirm = null
        notifyListeners()
        if (connect && link != null) connectLink(link)
    }

    /** A link now waits in [linkToConfirm]. */
    protected open fun onLinkToConfirm() {}

    /**
     * A link opened from outside the app that isn't a setup link (the phone: a followed
     * session's). The one that launched the app comes here too.
     */
    protected open fun onOtherLink(link: String) {}

    /**
     * A setup link: connects to its server and signs in with what it carries (a computer: the
     * server's setup token; a phone: a computer's pairing code). A computer key in it
     * ([Backend.computerKey]) goes to [addComputerKey] only when the link was [scanned] with the
     * in-app scanner, also when already signed in (a phone scanning one more computer): anyone can
     * send a link from outside the app, and a key it planted would let them read that computer's
     * sessions. A key that would replace another one held for that computer counts only once the
     * code's pairing code works ([codeWorks]): only a computer signed in to this server makes one.
     * Problems land in [authError], or in [notices] while signed in.
     */
    open suspend fun connectLink(link: String, scanned: Boolean = false) {
        val b = Backend.fromLink(link) ?: return
        val phone = role == DeviceRole.phone
        val secret = if (phone) Backend.pairingCode(link) else Backend.setupToken(link)
        val computer = if (scanned) Backend.computerKey(link) else null
        if (user != null) {
            if (b != backend) {
                // A phone keeps one server: a computer on another needs it to leave this one first.
                notice(
                    if (phone) {
                        "That code is for a computer on ${b.host}, and this phone is on $userName. To switch, leave " +
                            "this server (Account → Leave this server), then scan the code again."
                    } else {
                        "Sign out before switching to ${b.host}."
                    },
                )
            } else if (computer != null) {
                val held = computerKey(computer.desktop)
                val problem = if (held == null || held == computer.key) null else codeWorks(b, secret)
                if (problem != null) {
                    notice(problem)
                    return
                }
                addComputerKey(computer)
            } else if (phone && Backend.computerKey(link) != null) {
                notice("To connect to a computer, scan its code with PocketTerm's scanner.")
            }
            notifyListeners()
            return
        }
        if (secret == null) {
            authError = if (phone) {
                "That link has no sign-in code. On your computer, open PocketTerm: Settings → Phone → Add a phone…"
            } else {
                "That link has no setup token. On your server, run `pocketterm-server setup-link` and open the link " +
                    "it prints."
            }
            notifyListeners()
            return
        }
        if (b != backend) {
            val problem = b.check()
            if (problem != null) {
                authError = problem
                notifyListeners()
                return
            }
            connect(b)
        }
        authError = null
        retryLink = null
        notifyListeners()
        try {
            val s = server!!
            val account = if (phone) {
                s.redeemCode(secret, label = device, platform = platform)
            } else {
                s.redeemSetup(secret, label = device, platform = platform)
            }
            // Before the sign-in lands, so the computer shows unlocked at once.
            if (computer != null) addComputerKey(computer)
            setUser(account)
            return
        } catch (e: ServerException) {
            authError = when {
                e.code == "invalid_code" && phone -> CODE_USED
                e.code == "invalid_code" ->
                    "That setup link doesn't work: the server has a newer one. Run `pocketterm-server setup-link` on the " +
                        "server and open the link it prints."
                else -> e.message
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val problem = storageProblem(e)
            if (problem != null) {
                authError = problem
                retryLink = link
            } else {
                authError = "Sign-in failed: $e"
            }
        }
        notifyListeners()
    }

    /** Whether pairing [code] works on [backend]: it's redeemed by a sign-in of its own that leaves at once. Null when it did, else why not. */
    private suspend fun codeWorks(backend: Backend, code: String?): String? {
        if (code == null) return CODE_USED
        val probe = client(backend, MemoryDeviceTokens())
        return try {
            probe.redeemCode(code, label = device, platform = platform)
            probe.leave()
            null
        } catch (e: ServerException) {
            if (e.code == "invalid_code") CODE_USED else e.message
        } finally {
            probe.close()
        }
    }

    /** A client for [backend] keeping its sign-in in [tokens]. */
    protected open fun client(backend: Backend, tokens: DeviceTokens): Server = Server(backend, tokens)

    /** A computer's key from a scanned setup link: the phone keeps it, over any it held for that computer. */
    protected open suspend fun addComputerKey(computer: ComputerKey) {}

    /** This computer and its key, for the setup link a phone scans; null where there's none (a phone). */
    protected open suspend fun pairingComputer(): ComputerKey? = null

    /**
     * A setup link that signs a phone in (POST /v1/pair) and carries this computer's key
     * ([pairingComputer]): the code works once, for 10 minutes; the key until reset. Only while
     * signed in. Fails with a [PairingException] that says why.
     */
    suspend fun pairingLink(): String {
        val code = try {
            server!!.createPairingCode()
        } catch (e: ServerException) {
            throw PairingException(e.message)
        }
        return backend!!.linkWithCode(code, computer = pairingComputer())
    }

    /**
     * Opens [backend] (and remembers it): the one saved at launch, the setup screen's, or a setup
     * link's, with the sign-in this device kept for it. With [signInAtOnce] that's signed in before
     * the server says it still holds; otherwise once it did (or didn't answer). A refusal signs
     * out, with the reason. Switching needs the user signed out.
     */
    suspend fun connect(backend: Backend) {
        check(user == null) { "Sign out before switching servers." }
        close()
        val s = client(backend, deviceTokens)
        server = s
        saveBackend(backend)
        this.backend = backend
        authError = null
        notifyListeners()
        s.load()
        // Listening before anything can end it: a refusal emitted before a dispatched collector ran would be lost.
        ended = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            s.ended.collect {
                if (leaving == null) leaving = endedReason
                setUser(null)
            }
        }
        if (signInAtOnce) scope.launch(start = CoroutineStart.UNDISPATCHED) { s.recheck() } else s.recheck()
        setUser(s.account)
        timing("signed in")
    }

    /**
     * A launch shows the sign-in kept here at once and asks the server about it meanwhile: a phone,
     * which then shows what it had without waiting on the network. A computer asks first.
     */
    protected open val signInAtOnce: Boolean get() = false

    /** Why the sign-in is gone when the server stopped taking it (this device was removed, the server erased), worded for the person. */
    protected open val endedReason: String
        get() = if (role == DeviceRole.phone) {
            "Your sign-in ended on the server. Scan a new code from PocketTerm on your computer."
        } else {
            "Your sign-in ended on the server. Open your server's setup link to sign in again."
        }

    /** Signs out and forgets the server: the setup screen shows again. */
    suspend fun disconnect() {
        if (user != null) signOut()
        close()
        clearBackend()
        backend = null
        authError = null
        notifyListeners()
    }

    private fun close() {
        if (server == null) return
        ended?.cancel()
        ended = null
        server?.close()
        server = null
    }

    /** Runs once a user is signed in (sign-in, or launch while signed in). */
    protected open suspend fun onSignedIn(user: Account) {}

    /** Runs before signing out, while the token still works on the server. */
    protected open suspend fun onSigningOut() {}

    /** Runs once the sign-in is gone, however that happened (signed out here, the server ended it). */
    protected open suspend fun onSignedOut() {}

    /** [connect]'s restore and the server's answers both report the sign-in: only a change of device runs [onSignedIn] or [onSignedOut]. */
    private fun setUser(account: Account?) {
        val reason = signedOutReason
        if (account != null) {
            signedOutReason = null
            leaving = null
            linkToConfirm = null
        } else if (user != null || leaving != null) {
            signedOutReason = leaving ?: endedReason
            leaving = null
        }
        if (account?.device?.id == user?.device?.id) {
            user = account ?: user
            if (signedOutReason != reason) notifyListeners()
            return
        }
        user = account
        scope.launch(start = CoroutineStart.UNDISPATCHED) { if (account != null) onSignedIn(account) else onSignedOut() }
        notifyListeners()
    }

    /**
     * Signs out: this device leaves the server (its token stops working there, DELETE
     * /v1/devices/me) and forgets it here, also when [onSigningOut] or the server fails (offline).
     */
    suspend fun signOut() {
        if (leaving == null) leaving = "You signed out."
        try {
            onSigningOut()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: sign-out cleanup failed: $e")
        }
        try {
            server?.leave()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: the server missed the sign-out: $e")
        }
        forgetError()
        setUser(null)
    }

    /** A sign-in that went before leaves no problem behind for the next one. */
    private fun forgetError() {
        authError = null
        retryLink = null
    }

    /** This computer runs the server it's connected to: only then may it erase it ([eraseServer]). */
    open val hostsServer: Boolean get() = false

    /** Erases everything on the server ([hostsServer] only): every computer and phone is signed out, the images and push registrations go. */
    suspend fun eraseServer() {
        check(hostsServer) { "Only the computer running the server erases it." }
        try {
            onSigningOut()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: sign-out cleanup failed: $e")
        }
        server!!.erase()
        leaving = "This server's data was erased."
        forgetError()
        setUser(null)
    }

    /** What this device's sign-in is called on screen: its server. */
    val userName: String get() = backend?.host ?: "you"

    override fun dispose() {
        ended?.cancel()
        links?.cancel()
        super.dispose()
    }

    companion object {
        private const val CODE_USED =
            "That code doesn't work: it was used, or it's more than 10 minutes old. Make a new one on your computer " +
                "(Settings → Phone → Add a phone…)."
    }
}

/** Why a pairing code couldn't be made, worded for the person. */
class PairingException(override val message: String) : Exception(message) {
    override fun toString(): String = message
}
