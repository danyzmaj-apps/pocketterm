package com.danyzmaj.pocketterm.ui.voice

import com.danyzmaj.pocketterm.core.SpeechCheck
import com.danyzmaj.pocketterm.core.SpeechEnd
import com.danyzmaj.pocketterm.core.SpeechEvent
import com.danyzmaj.pocketterm.core.SpeechFix
import com.danyzmaj.pocketterm.core.SpeechLanguage
import com.danyzmaj.pocketterm.core.SpeechSource
import com.danyzmaj.pocketterm.core.SpeechStatus
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.sin

/**
 * An E2E build's speaker (no microphone on the emulator): says [words] (else a sentence in the
 * language it listens in) one by one, a loudness swinging with each, then goes quiet until stopped.
 * Maestro's voice flow waits for these exact sentences.
 */
class ScriptedSpeech(private val words: List<String>? = null) : SpeechSource {
    private var out: SendChannel<SpeechEvent>? = null
    private var ticker: Job? = null
    private var said = ""

    override suspend fun check(language: SpeechLanguage) = SpeechCheck(SpeechStatus.ready)

    override suspend fun support(language: SpeechLanguage) = SpeechCheck(SpeechStatus.ready)

    override fun listen(language: SpeechLanguage): Flow<SpeechEvent> = callbackFlow {
        ticker?.cancel()
        said = ""
        val words = words ?: if (language == SpeechLanguage.croatian) croatian else sentence
        out = channel
        // A word every third tick of 120 ms, the level swinging on every tick.
        val job = launch {
            var tick = 0
            while (true) {
                delay(120)
                tick++
                val word = tick / 3
                trySend(SpeechEvent.Level(if (word < words.size) .45 + .4 * abs(sin(tick * 1.3)) else .04))
                if (tick % 3 == 0 && word <= words.size) {
                    said = words.take(word).joinToString(" ")
                    trySend(SpeechEvent.Heard(said))
                }
            }
        }
        ticker = job
        awaitClose {
            job.cancel()
            if (out === channel) out = null
        }
    }

    override suspend fun stop() {
        ticker?.cancel()
        // Stopped already (or never listening): nothing to settle.
        val o = out ?: return
        out = null
        o.trySend(SpeechEvent.Heard(said))
        o.trySend(SpeechEvent.Ended(SpeechEnd.stopped))
        o.close()
    }

    override suspend fun fix(fix: SpeechFix, language: SpeechLanguage) {}

    private companion object {
        val sentence = listOf(
            "Add", "a", "dark", "mode", "toggle", "to", "the", "settings", "page", "and", "write", "a", "test", "for", "it.",
        )
        val croatian = listOf("Dodaj", "tamni", "način", "rada", "u", "postavke", "i", "napiši", "test", "za", "to.")
    }
}
