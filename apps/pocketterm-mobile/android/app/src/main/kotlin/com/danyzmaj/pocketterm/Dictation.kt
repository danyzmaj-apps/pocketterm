package com.danyzmaj.pocketterm

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.annotation.RequiresApi
import com.danyzmaj.pocketterm.core.SpeechCheck
import com.danyzmaj.pocketterm.core.SpeechEvent
import com.danyzmaj.pocketterm.core.SpeechFix
import com.danyzmaj.pocketterm.core.SpeechLanguage
import com.danyzmaj.pocketterm.core.SpeechSource
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.Locale
import kotlin.coroutines.resume

/**
 * The composer's microphone ([SpeechSource]): speech to text on the phone, in the
 * language asked for (`en` or `hr`). Android 12+: the on-device recognizer
 * (SpeechRecognizer.createOnDeviceSpeechRecognizer), with Android 13+ checking that the language is installed for
 * it; otherwise the phone's recognizer, asked to stay offline
 * (EXTRA_PREFER_OFFLINE). Android's recognizer stops at each pause, so while the person is still listening a new
 * round starts at once and the text so far is kept.
 *
 * A listening is a flow ([listen]) of {type: heard, text}, {type: level, level 0…1}, then
 * {type: ended, why: stopped|interrupted|error, message?, status?} ([SpeechEvent.fromMap]) and its end.
 * Cancelling the collection discards. Runs on the main thread, as SpeechRecognizer wants.
 */
class Dictation(private val activity: Context) : SpeechSource {
    private val main = Handler(Looper.getMainLooper())
    private var sink: SendChannel<SpeechEvent>? = null
    private var recognizer: SpeechRecognizer? = null
    private var listening = false
    private var stopping = false
    private var stopWhy = "stopped"
    private var stopTimeout: Runnable? = null

    /** Settled words of the rounds before, and the current round's words. */
    private var settled = ""
    private var partial = ""

    /** When the current round started; rounds that keep ending at once mean the recognizer is failing. */
    private var roundAt = 0L
    private var quickEnds = 0

    /** The language of the current listening, as onListen was given it. */
    private var listeningIn = "en"

    /**
     * The recognizer's tag for [code] (a SpeechLanguage.code): English British when the phone's first English
     * language is, else American; Croatian hr-HR.
     */
    private fun tag(code: String?): String {
        if (code == "hr") return "hr-HR"
        val locales = activity.resources.configuration.locales
        for (i in 0 until locales.size()) {
            val l = locales[i]
            if (l.language == "en") return if (l.country == "GB") "en-GB" else "en-US"
        }
        return if (Locale.getDefault().country == "GB") "en-GB" else "en-US"
    }

    private val onDevice: Boolean
        get() = Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)

    private fun intent(code: String?) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
        .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        .putExtra(RecognizerIntent.EXTRA_LANGUAGE, tag(code))
        .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        .putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)

    // ------------------------------------------------------------------ methods

    override suspend fun check(language: SpeechLanguage): SpeechCheck {
        if (!ActivityHost.request(Manifest.permission.RECORD_AUDIO)) {
            return SpeechCheck.fromMap(mapOf("status" to "denied", "fix" to "appSettings"))
        }
        return support(language)
    }

    /** Whether the language can be recognized on this phone, asking for no permission. */
    override suspend fun support(language: SpeechLanguage): SpeechCheck = SpeechCheck.fromMap(
        when {
            // Before Android 12, or no on-device recognizer: the phone's own, asked to stay offline.
            !onDevice -> mapOf("status" to if (SpeechRecognizer.isRecognitionAvailable(activity)) "ready" else "unavailable")
            // Android 12 can't say which languages it has: a missing language shows when listening starts.
            Build.VERSION.SDK_INT < 33 -> mapOf("status" to "ready")
            else -> checkLanguage(language.code)
        },
    )

    @RequiresApi(33)
    private suspend fun checkLanguage(code: String?): Map<String, Any?> = suspendCancellableCoroutine { cont ->
        val r = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
        val lang = tag(code)
        fun has(list: List<String>) = list.any { it.equals(lang, ignoreCase = true) }
        r.checkRecognitionSupport(
            intent(code),
            activity.mainExecutor,
            object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    r.destroy()
                    cont.resume(
                        when {
                            has(support.installedOnDeviceLanguages) -> mapOf("status" to "ready")
                            has(support.pendingOnDeviceLanguages) -> mapOf("status" to "downloading")
                            has(support.supportedOnDeviceLanguages) -> mapOf("status" to "noLanguage", "fix" to "download")
                            // Not even to download: this phone's on-device recognizer doesn't do the language.
                            else -> mapOf("status" to "noLanguage")
                        },
                    )
                }

                override fun onError(error: Int) {
                    r.destroy()
                    // It couldn't say: listening finds out.
                    cont.resume(mapOf("status" to "ready"))
                }
            },
        )
    }

    override suspend fun fix(fix: SpeechFix, language: SpeechLanguage) {
        when {
            fix == SpeechFix.download && Build.VERSION.SDK_INT >= 33 -> {
                // The system downloads it, with its own notification; the recognizer stays bound a while for that.
                val r = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
                r.triggerModelDownload(intent(language.code))
                main.postDelayed({ r.destroy() }, 10_000)
            }
            fix == SpeechFix.speechSettings -> open(Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)) || openApp()
            else -> openApp()
        }
    }

    private fun open(intent: Intent) = ActivityHost.start(intent)

    private fun openApp() =
        open(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null)))

    override suspend fun stop() {
        finish("stopped")
    }

    // ------------------------------------------------------------------ listening

    override fun listen(language: SpeechLanguage): Flow<SpeechEvent> = callbackFlow {
        start(language.code, channel)
        awaitClose { main.post { cancel(channel) } }
    }

    private fun start(code: String, events: SendChannel<SpeechEvent>) {
        teardown()
        listeningIn = code
        sink = events
        settled = ""
        partial = ""
        listening = true
        stopping = false
        quickEnds = 0
        val r = if (onDevice) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
        } else {
            SpeechRecognizer.createSpeechRecognizer(activity)
        }
        r.setRecognitionListener(listener)
        recognizer = r
        roundAt = System.currentTimeMillis()
        r.startListening(intent(listeningIn))
    }

    private fun cancel(events: SendChannel<SpeechEvent>) {
        // Closed or cancelled: what was heard goes, and the microphone stops now. A later listening is its own.
        if (sink !== events && sink != null) return
        sink = null
        listening = false
        teardown()
    }

    /** Stops listening; the recognizer's last result ends it, or after 2 s what was heard so far does. */
    private fun finish(why: String) {
        if (!listening || stopping) return
        stopping = true
        stopWhy = why
        recognizer?.stopListening()
        stopTimeout = Runnable { end(stopWhy) }.also { main.postDelayed(it, 2000) }
    }

    private fun end(why: String, message: String? = null, status: String? = null) {
        if (!listening) return
        listening = false
        settle()
        val s = sink
        sink = null
        s?.trySend(SpeechEvent.Heard(settled))
        s?.trySend(SpeechEvent.fromMap(listOfNotNull("type" to "ended", "why" to why, message?.let { "message" to it }, status?.let { "status" to it }).toMap()))
        s?.close()
        teardown()
    }

    private fun teardown() {
        stopTimeout?.let { main.removeCallbacks(it) }
        stopTimeout = null
        recognizer?.destroy()
        recognizer = null
    }

    private fun settle() {
        settled = joined(settled, partial)
        partial = ""
    }

    private fun emitText() {
        sink?.trySend(SpeechEvent.Heard(joined(settled, partial)))
    }

    /** The round ended at a pause while the person still listens: a new one starts, the words so far kept. */
    private fun nextRound() {
        settle()
        val now = System.currentTimeMillis()
        quickEnds = if (now - roundAt < 1000) quickEnds + 1 else 0
        if (quickEnds >= 4) return end("error", "Speech recognition keeps stopping")
        roundAt = now
        recognizer?.startListening(intent(listeningIn))
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onRmsChanged(rmsdB: Float) {
            // Android reports about -2 dB (silence) to 10 dB (loud speech).
            if (listening && !stopping) {
                sink?.trySend(SpeechEvent.Level(((rmsdB + 2f) / 12f).coerceIn(0f, 1f).toDouble()))
            }
        }

        override fun onPartialResults(results: Bundle?) {
            first(results)?.let {
                partial = it
                emitText()
            }
        }

        override fun onResults(results: Bundle?) {
            first(results)?.let { partial = it }
            if (stopping) return end(stopWhy)
            emitText()
            nextRound()
        }

        override fun onError(error: Int) {
            if (!listening) return
            if (stopping) return end(stopWhy)
            when (error) {
                SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT, SpeechRecognizer.ERROR_CLIENT ->
                    nextRound()
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> main.postDelayed({ if (listening && !stopping) nextRound() }, 200)
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> end("error", "No microphone permission", "denied")
                // Android 12 learns only now that the language isn't on the phone.
                ERROR_LANGUAGE_NOT_SUPPORTED, ERROR_LANGUAGE_UNAVAILABLE ->
                    end("error", "${Locale.forLanguageTag(tag(listeningIn)).getDisplayLanguage(Locale.ENGLISH)} isn't on this phone for speech recognition", "noLanguage")
                // A call or another app took the microphone.
                SpeechRecognizer.ERROR_AUDIO -> end("interrupted")
                else -> end("error", "Speech recognition failed ($error)")
            }
        }
    }

    private fun first(results: Bundle?) =
        results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.takeIf { it.isNotBlank() }

    companion object {
        // SpeechRecognizer's, from API 31.
        private const val ERROR_LANGUAGE_NOT_SUPPORTED = 12
        private const val ERROR_LANGUAGE_UNAVAILABLE = 13

        fun joined(a: String, b: String) = when {
            a.isEmpty() -> b
            b.isEmpty() -> a
            else -> "$a $b"
        }
    }
}
