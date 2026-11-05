package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.flow.Flow
import java.util.Locale

/**
 * What the phone listens for. [code] is the BCP 47 language the native recognizers take (`en`:
 * British or American by the phone's region; `hr`: hr-HR).
 */
enum class SpeechLanguage(
    val code: String,
    /** Its name in the app's own English, for sentences ("Croatian for speech recognition…"). */
    val title: String,
    /** Its own name, as the voice sheet and Settings offer it. */
    val label: String,
) {
    english("en", "English", "English"),
    croatian("hr", "Croatian", "Hrvatski");

    companion object {
        /** The preference the chosen language is kept under, a [SpeechLanguage]'s name; none is Auto. */
        const val prefsKey = "voiceLanguage"

        /**
         * The languages PocketTerm can listen for in the order the phone's [locales] list them, then
         * English if they don't: Auto's candidates, the first the phone can recognize winning.
         */
        fun byLocales(locales: Iterable<Locale>): List<SpeechLanguage> {
            val out = LinkedHashSet<SpeechLanguage>()
            for (l in locales) entries.firstOrNull { it.code == l.language }?.let(out::add)
            out.add(english)
            return out.toList()
        }
    }
}

/** Whether the phone can listen now, in the chosen [SpeechLanguage], on the device. */
enum class SpeechStatus {
    ready,

    /** The microphone (or speech recognition) was refused. */
    denied,

    /** Turned off for this phone (a device profile). */
    restricted,

    /** The language isn't on the device; [SpeechCheck.fix] says whether it can be fetched or added, none: never. */
    noLanguage,

    /** The language for the device is on its way. */
    downloading,

    /** This phone can't recognize speech on the device at all. */
    unavailable,
}

/** What the person can do about a [SpeechStatus] that isn't ready. */
enum class SpeechFix {
    /** PocketTerm's page in the phone's Settings (its permissions). */
    appSettings,

    /** Fetch the language's model for on-device recognition. Recognition itself still never leaves the phone. */
    download,

    /** The phone's own speech settings, where a language for on-device recognition is turned on. */
    speechSettings,
}

/** A [SpeechStatus] and what can be done about it. */
data class SpeechCheck(val status: SpeechStatus, val fix: SpeechFix? = null) {
    val ready: Boolean get() = status == SpeechStatus.ready

    /** This phone can't listen in the language, whatever the person does. */
    val unsupported: Boolean get() = status == SpeechStatus.unavailable || (status == SpeechStatus.noLanguage && fix == null)

    companion object {
        /** The native recognizer's answer `{status, fix?}`; an unknown status reads as unavailable. */
        fun fromMap(m: Map<String, Any?>) = SpeechCheck(
            SpeechStatus.entries.firstOrNull { it.name == m["status"] } ?: SpeechStatus.unavailable,
            SpeechFix.entries.firstOrNull { it.name == m["fix"] },
        )
    }
}

/** How a listening session ended. */
enum class SpeechEnd {
    /** Stopped as asked ([SpeechSource.stop]). */
    stopped,

    /** Something else took the microphone (a call, an assistant, the app left the screen). */
    interrupted,

    /** Recognition failed; [SpeechEvent.Ended.message] says why. */
    error,
}

/** What a listening session reports, in order, the last one [Ended]. */
sealed class SpeechEvent {
    /** Everything heard since listening started, the newest words possibly still changing. */
    data class Heard(val text: String) : SpeechEvent()

    /** How loud the microphone is, 0 (silence) to 1. */
    data class Level(val level: Double) : SpeechEvent()

    /** The end; [status] when the failure is one [SpeechSource.check] would have found. */
    data class Ended(val why: SpeechEnd, val message: String? = null, val status: SpeechStatus? = null) : SpeechEvent()

    companion object {
        /**
         * A native recognizer's event: `{type: heard, text}`, `{type: level, level}`,
         * `{type: ended, why: stopped|interrupted|error, message?, status?}`; anything else ends it.
         */
        fun fromMap(m: Map<String, Any?>): SpeechEvent = when (m["type"]) {
            "heard" -> Heard(m["text"] as? String ?: "")
            "level" -> Level(((m["level"] as? Number)?.toDouble() ?: 0.0).coerceIn(0.0, 1.0))
            else -> Ended(
                SpeechEnd.entries.firstOrNull { it.name == m["why"] } ?: SpeechEnd.error,
                m["message"] as? String,
                SpeechStatus.entries.firstOrNull { it.name == m["status"] },
            )
        }
    }
}

/** Speech to text on the phone, in one [SpeechLanguage] and on the device only; the app implements it. */
interface SpeechSource {
    /** Whether it can listen in [language]; asks for the permissions it needs the first time. */
    suspend fun check(language: SpeechLanguage): SpeechCheck

    /**
     * Whether the phone has [language] for on-device recognition, asking for no permission. Ready
     * when it can't tell (Android 12 and older); listening finds out.
     */
    suspend fun support(language: SpeechLanguage): SpeechCheck

    /**
     * Starts listening in [language]. Cancelling the collection discards what was heard and stops at
     * once; [stop] ends it with the last words settled instead. The flow completes after [SpeechEvent.Ended].
     */
    fun listen(language: SpeechLanguage): Flow<SpeechEvent>

    /** Stops listening: the last [SpeechEvent.Heard], then [SpeechEvent.Ended] with [SpeechEnd.stopped]. */
    suspend fun stop()

    /** Does [fix] for [language]; for [SpeechFix.download], returns once the download is done or handed to the system. */
    suspend fun fix(fix: SpeechFix, language: SpeechLanguage)
}
