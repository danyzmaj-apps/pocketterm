package com.danyzmaj.pocketterm.ui.session

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import com.danyzmaj.pocketterm.core.Analytics
import com.danyzmaj.pocketterm.core.Agent
import com.danyzmaj.pocketterm.core.ChatAttachment
import com.danyzmaj.pocketterm.core.ChatAttachments
import com.danyzmaj.pocketterm.core.ChatFile
import com.danyzmaj.pocketterm.core.ChatImage
import com.danyzmaj.pocketterm.core.LiveActivities
import com.danyzmaj.pocketterm.core.LiveCommand
import com.danyzmaj.pocketterm.core.LiveSummary
import com.danyzmaj.pocketterm.core.LiveView
import com.danyzmaj.pocketterm.core.PromptFile
import com.danyzmaj.pocketterm.core.TermCap
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.core.routedKey
import com.danyzmaj.pocketterm.state.Drafts
import com.danyzmaj.pocketterm.ui.Nav
import com.danyzmaj.pocketterm.ui.common.Haptics
import com.danyzmaj.pocketterm.ui.common.Toaster
import com.danyzmaj.pocketterm.ui.queue.sessionTitle
import com.danyzmaj.pocketterm.ui.voice.VoiceResult
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Why [agent]'s slash commands can't be sent from here. */
fun noCommands(agent: Agent): String =
    "Slash commands are typed into ${agent.label}’s terminal window, and PocketTerm can’t reach this one: it isn’t in " +
        "kitty, tmux, WezTerm, iTerm2 or Ghostty. Run them on the computer."

/**
 * One coding session's page, without the UI: the composer's text and attachments, prompts on their way
 * (shown as the person's own until the transcript has them), and what the page does — prompt, steer or
 * queue, stop, follow, answer a restart's Continue. Lives as long as the page; its coroutines run on the
 * page's [scope], so they end with it.
 */
@Stable
class SessionModel(
    val remote: TerminalRemote,
    val key: String,
    /** Just launched: its agent may not have reported yet. */
    val starting: Boolean,
    offerContinue: Boolean,
    autoContinue: Boolean,
    private val scope: CoroutineScope,
    private val drafts: Drafts,
    private val analytics: Analytics,
) {
    /** Set by the page each composition. */
    lateinit var toaster: Toaster
    lateinit var nav: Nav
    lateinit var haptics: Haptics

    val attachments = ChatAttachments(AndroidImageCodec)
    val list = LazyListState()
    val focus = FocusRequester()

    // The unsent text is kept per session (Drafts); attachments aren't.
    private val draftKey = routedKey(remote.desktopId, key)
    private var savedDraft = drafts.load(draftKey)
    var field by mutableStateOf(TextFieldValue(savedDraft, TextRange(savedDraft.length)))

    var sending by mutableStateOf(false)
    var stopping by mutableStateOf(false)
    var followUp by mutableStateOf(false)
    var loadingOlder by mutableStateOf(false)

    /** The close button was tapped: the page asks. */
    var closing by mutableStateOf(false)

    /** [SessionRoute.offerContinue] until Continue went. */
    var continueOffer by mutableStateOf(offerContinue)

    /** [SessionRoute.autoContinue] until `continue` went out. */
    private var autoContinue = autoContinue

    /** The session has been in the computer's state since the page opened. */
    var seen = false

    /** Tool items and notices showing whole. */
    val expanded = mutableStateMapOf<String, Boolean>()

    /** Prompts sent from here that haven't come back in the transcript yet, oldest first; [outgoingTick] moves as it changes. */
    val outgoing = mutableListOf<Outgoing>()
    var outgoingTick by mutableIntStateOf(0)

    /** One of [outgoing] is on its way to the computer. */
    val delivering: Boolean get() = outgoing.any { it.sending }

    /** The transcript's epoch the page laid out last: a new one starts over at the bottom. */
    var epoch: String? = null

    val continueListener: () -> Unit = { continueWhenReady() }

    fun saveDraft() {
        val text = field.text
        if (text == savedDraft) return
        savedDraft = text
        drafts.save(draftKey, text)
    }

    fun dispose() {
        saveDraft()
        remote.removeListener(continueListener)
        attachments.dispose()
    }

    /** The terminal window the agent runs in, if it runs in one (a launched one before it reports: the session's key is its window's). */
    fun windowKey(s: LiveSummary?): String? = s?.window ?: if (remote.window(key) != null) key else null

    /** Whether there's a [window] and its terminal can do [cap]; one not in the list yet (just launched) can do everything. */
    fun can(window: String?, cap: TermCap): Boolean = window != null && (remote.window(window)?.can(cap) ?: true)

    /** The session's agent: as it reports, else its window's program, else the one the computer starts (a just-launched session). */
    fun agent(s: LiveSummary?): Agent = s?.agent ?: remote.window(key)?.agent ?: remote.agent

    private fun toast(text: String) = toaster.show(text)

    /** Back to the newest, by the composer. */
    fun toBottom() {
        scope.launch { list.scrollToItem(0) }
    }

    fun setText(text: String) {
        field = TextFieldValue(text, TextRange(text.length))
    }

    fun attach(sources: AttachSources, from: String) {
        scope.launch {
            attempt {
                when (from) {
                    "photos" -> sources.photos()
                    "files" -> sources.files()
                    else -> if (!sources.paste()) toast("There is no image on the clipboard.")
                }
            }.onFailure { toast(problemText(it)) }
        }
    }

    fun send(busy: Boolean) {
        val typed = field.text
        val text = typed.trim()
        if ((text.isEmpty() && attachments.isEmpty) || attachments.loading || sending || delivering) return
        val attached = attachments.items.toList()
        // A slash command is typed into the agent's window, where its editor reads it; sent as a prompt,
        // the agent would take it for chat.
        val command = text.startsWith("/")
        if (command && attached.isNotEmpty()) return toast("Slash commands can't take images or files.")
        val s = remote.session(key)
        if (command && !can(windowKey(s), TermCap.line)) return toast(noCommands(agent(s)))
        val queue = busy && (followUp || !agent(s).steers)
        haptics.done()
        val mode = when {
            command -> "command"
            queue -> "queue"
            busy -> "steer"
            else -> "prompt"
        }
        analytics.event("prompt_sent", "mode" to mode, "attachments" to attached.isNotEmpty())
        if (!command) return prompt(text, attached, followUp = queue)
        sending = true
        scope.launch {
            attempt {
                val before = remote.session(key)?.id
                remote.prompt(key, text, followUp = queue)
                remote.session(key)?.window?.let { window -> scope.launch { menuOrScreen(window, before) } }
                // Only what went: the field stays editable while it goes, and what was typed meanwhile is the next prompt.
                val now = field.text
                setText(if (now.startsWith(typed)) now.substring(typed.length).trimStart() else now)
                toBottom()
            }.onFailure { toast(problemText(it)) }
            sending = false
        }
    }

    /**
     * What was said: Send then sends it all as Send would now (steering, queued or not, with the
     * attachments), and what can't go yet stays in the field. Insert leaves it there to go on typing.
     */
    fun voiced(r: VoiceResult) {
        setText(r.text)
        if (r.send) {
            send(busy = remote.session(key)?.busy ?: false)
        } else {
            scope.launch {
                // After the sheet has gone and given the focus back.
                delay(100)
                attempt { focus.requestFocus() }
            }
        }
    }

    /** Sends [text] and [attached] as the person's message, which shows at once while the field and the attachments are free for the next one. */
    private fun prompt(text: String, attached: List<ChatAttachment>, followUp: Boolean) {
        // A prompt of their own replaces the `continue` a restart would send, and says what comes next instead of Continue.
        if (autoContinue) {
            autoContinue = false
            remote.removeListener(continueListener)
        }
        continueOffer = false
        val o = Outgoing(text, attached, followUp, remote.view(key))
        setText("")
        attachments.removeSent(attached)
        outgoing.add(o)
        outgoingTick++
        toBottom()
        scope.launch { deliver(o) }
    }

    /** Sends [o] (again): a failure stays on its bubble, with why. */
    suspend fun deliver(o: Outgoing) {
        o.sending = true
        o.problem = null
        attempt {
            remote.prompt(
                key,
                o.text,
                images = o.attachments.filterIsInstance<ChatImage>().map { it.bytes },
                files = o.attachments.filterIsInstance<ChatFile>().map { PromptFile(it.name, it.mime, it.bytes) },
                followUp = o.followUp,
            )
        }.onSuccess { queued ->
            o.queued = queued
            // Followed from here on (in the notifications), as working.
            prompted()
        }.onFailure { o.problem = problemText(it) }
        o.sending = false
    }

    private fun prompted() {
        val s = remote.session(key) ?: return
        val activities = remote.activities ?: return
        scope.launch { attempt { activities.prompted(key, sessionTitle(s)) } }
    }

    fun retry(o: Outgoing) {
        scope.launch { deliver(o) }
    }

    /** Prompts `continue`: the run a restart from the phone stopped carries on. Once; again only if it didn't go. */
    fun sendContinue() {
        continueOffer = false
        scope.launch {
            attempt {
                remote.prompt(key, "continue")
                prompted()
                toBottom()
            }.onFailure {
                continueOffer = true
                toast(problemText(it))
            }
        }
    }

    /** [SessionRoute.autoContinue]: prompts `continue` once the session is there, at rest, and the phone is online. */
    fun continueWhenReady() {
        if (!autoContinue) return
        val s = remote.session(key)
        if (!remote.online || s == null || s.busy || sending) return
        autoContinue = false
        remote.removeListener(continueListener)
        sendContinue()
    }

    /** Listens for the moment `continue` can go, when the page came from a switch that stopped a run. */
    fun startAutoContinue() {
        if (!autoContinue) return
        remote.addListener(continueListener)
        continueWhenReady()
    }

    /**
     * A command's picker (/resume, /model, /tree …) shows here as a menu once the computer has read it off
     * the agent's screen; when none comes (a command without one, or one the computer can't read), its
     * screen opens instead. A command that renewed the session (/new, /clear) shows its result here, so
     * nothing opens: [before] is the session's id when it was sent.
     */
    private suspend fun menuOrScreen(window: String, before: String?) {
        fun renewed() = before != null && (remote.session(key)?.id ?: before) != before
        repeat(12) {
            delay(250)
            if (remote.session(key)?.ask?.isMenu == true || renewed()) return
        }
        if (renewed()) return
        if (nav.showingSession(key) && can(window, TermCap.read)) nav.openTerminal(window)
    }

    /** Puts `/name ` in the field, the cursor after it. */
    fun complete(c: LiveCommand) = setText("/${c.name} ")

    fun toggleFollow(activities: LiveActivities, s: LiveSummary) {
        scope.launch {
            if (activities.following(key)) {
                attempt { activities.stop(key) }.onFailure { toast(problemText(it)) }
                return@launch
            }
            attempt { activities.follow(key, sessionTitle(s)) }
                .onSuccess { on -> if (!on) toast("Notifications are off for PocketTerm: turn them on in Settings → Apps → PocketTerm.") }
                .onFailure { toast(problemText(it)) }
        }
    }

    fun stop() {
        stopping = true
        scope.launch {
            attempt { remote.abort(key) }.onFailure { toast(problemText(it)) }
            stopping = false
        }
    }

    fun older() {
        loadingOlder = true
        scope.launch {
            attempt { remote.older(key) }.onFailure { toast(problemText(it)) }
            loadingOlder = false
        }
    }

    /**
     * Prompts sent from here as they stand against the transcript [v] and the session [s]: those whose item
     * has come back go (they show as it, in their place), and so do queued ones once the queue strip lists
     * them, or once the run is over (it went to the agent).
     */
    fun settleOutgoing(v: LiveView?, s: LiveSummary?) {
        if (outgoing.isEmpty()) return
        if (v != null) {
            val back = cameBack(outgoing, v)
            outgoing.removeAll { it in back }
        }
        if (s != null && outgoing.isNotEmpty()) {
            val waiting = s.queue.map { it.id }.toSet()
            val atRest = !s.busy && s.ask == null
            outgoing.removeAll { it.queued != null && (it.queued in waiting || atRest) }
        }
    }
}
