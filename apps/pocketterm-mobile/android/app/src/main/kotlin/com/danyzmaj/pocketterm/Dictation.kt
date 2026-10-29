package com.danyzmaj.pocketterm

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
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
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * The composer's microphone (packages/pocketterm_core/lib/speech.dart): speech to text on the phone, in the
 * language Dart asks for (`en` or `hr`). Android 12+: the on-device recognizer
 * (SpeechRecognizer.createOnDeviceSpeechRecognizer), with Android 13+ checking that the language is installed for
 * it; otherwise the phone's recognizer, asked to stay offline
 * (EXTRA_PREFER_OFFLINE). Android's recognizer stops at each pause, so while the person is still listening a new
 * round starts at once and the text so far is kept.
 *
 * Methods (from MainActivity's channel): speechCheck {language} → {status, fix?}, speechStop, speechFix {fix,
 * language}. Events on `pocketterm/speech`, listened to with {language}, a stream per listening: {type: heard,
 * text}, {type: level, level 0…1}, then
 * {type: ended, why: stopped|interrupted|error, message?, status?} and the stream's end. Cancelling it discards.
 */
class Dictation(private val activity: Activity) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
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

    private var micWaiter: ((Boolean) -> Unit)? = null

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

    fun check(code: String?, result: MethodChannel.Result) {
        askMic { granted ->
            when {
                !granted -> result.success(mapOf("status" to "denied", "fix" to "appSettings"))
                // Before Android 12, or no on-device recognizer: the phone's own, asked to stay offline.
                !onDevice -> result.success(
                    mapOf("status" to if (SpeechRecognizer.isRecognitionAvailable(activity)) "ready" else "unavailable"),
                )
                // Android 12 can't say which languages it has: a missing language shows when listening starts.
                Build.VERSION.SDK_INT < 33 -> result.success(mapOf("status" to "ready"))
                else -> checkLanguage(code, result)
            }
        }
    }

    @RequiresApi(33)
    private fun checkLanguage(code: String?, result: MethodChannel.Result) {
        val r = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
        val lang = tag(code)
        fun has(list: List<String>) = list.any { it.equals(lang, ignoreCase = true) }
        r.checkRecognitionSupport(
            intent(code),
            activity.mainExecutor,
            object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    r.destroy()
                    result.success(
                        when {
                            has(support.installedOnDeviceLanguages) -> mapOf("status" to "ready")
                            has(support.pendingOnDeviceLanguages) -> mapOf("status" to "downloading")
                            has(support.supportedOnDeviceLanguages) -> mapOf("status" to "noLanguage", "fix" to "download")
                            else -> mapOf("status" to "noLanguage", "fix" to "speechSettings")
                        },
                    )
                }

                override fun onError(error: Int) {
                    r.destroy()
                    // It couldn't say: listening finds out.
                    result.success(mapOf("status" to "ready"))
                }
            },
        )
    }

    fun fix(fix: String?, code: String?, result: MethodChannel.Result) {
        when {
            fix == "download" && Build.VERSION.SDK_INT >= 33 -> {
                // The system downloads it, with its own notification; the recognizer stays bound a while for that.
                val r = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
                r.triggerModelDownload(intent(code))
                main.postDelayed({ r.destroy() }, 10_000)
            }
            fix == "speechSettings" -> open(Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)) || openApp()
            else -> openApp()
        }
        result.success(null)
    }

    private fun open(intent: Intent) = runCatching { activity.startActivity(intent) }.isSuccess

    private fun openApp() =
        open(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null)))

    /** RECORD_AUDIO, asked for the first time the microphone is used. */
    private fun askMic(then: (Boolean) -> Unit) {
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            return then(true)
        }
        micWaiter?.invoke(false)
        micWaiter = then
        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
    }

    /** From MainActivity.onRequestPermissionsResult. */
    fun micAnswered(granted: Boolean) {
        val w = micWaiter
        micWaiter = null
        w?.invoke(granted)
    }

    fun stop(result: MethodChannel.Result) {
        result.success(null)
        finish("stopped")
    }

    // ------------------------------------------------------------------ listening

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        teardown()
        listeningIn = (arguments as? Map<*, *>)?.get("language") as? String ?: "en"
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

    override fun onCancel(arguments: Any?) {
        // Closed or cancelled: what was heard goes, and the microphone stops now.
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
        s?.success(mapOf("type" to "heard", "text" to settled))
        s?.success(listOfNotNull("type" to "ended", "why" to why, message?.let { "message" to it }, status?.let { "status" to it }).toMap())
        s?.endOfStream()
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
        sink?.success(mapOf("type" to "heard", "text" to joined(settled, partial)))
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
                sink?.success(mapOf("type" to "level", "level" to ((rmsdB + 2f) / 12f).coerceIn(0f, 1f).toDouble()))
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
        const val MIC_REQUEST = 0x0D2F

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
