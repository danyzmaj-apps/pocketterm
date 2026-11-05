package com.danyzmaj.pocketterm.state

import com.danyzmaj.pocketterm.core.ChangeNotifier
import com.danyzmaj.pocketterm.core.PreferenceStore
import com.danyzmaj.pocketterm.core.SpeechCheck
import com.danyzmaj.pocketterm.core.SpeechLanguage
import com.danyzmaj.pocketterm.core.SpeechSource
import com.danyzmaj.pocketterm.core.SpeechStatus
import kotlinx.coroutines.CancellationException
import java.util.Locale

/**
 * The language voice prompts are heard in, kept per phone ([SpeechLanguage.prefsKey], a
 * [SpeechLanguage]'s name; absent is Auto). [locales]: the phone's languages, in its order.
 */
class VoiceLanguage(private val prefs: PreferenceStore, private val locales: () -> List<Locale>) : ChangeNotifier() {
    /** What was chosen; null for Auto. */
    var choice: SpeechLanguage? = SpeechLanguage.entries.firstOrNull { it.name == prefs.getString(SpeechLanguage.prefsKey) }
        private set

    /**
     * Languages Auto listened in and the phone then said it has none of (Android 12 can't tell
     * before listening): Auto passes over them until a language is chosen again.
     */
    private val missing = mutableSetOf<SpeechLanguage>()

    /** Auto's first guess, before asking the phone: its first language PocketTerm can listen for. */
    val guess: SpeechLanguage get() = SpeechLanguage.byLocales(locales()).first()

    /** What it listens in: the choice, else [auto]. */
    suspend fun resolve(source: SpeechSource): SpeechLanguage = choice ?: auto(source)

    /**
     * Auto: of the phone's languages PocketTerm can listen for (in the phone's order, then English),
     * the first the phone has for on-device recognition; when none is there yet, the first it can get
     * (a download, a setting); English when it can get none.
     */
    suspend fun auto(source: SpeechSource): SpeechLanguage {
        val candidates = SpeechLanguage.byLocales(locales()).filter { it !in missing }
        val found = mutableMapOf<SpeechLanguage, SpeechCheck>()
        for (l in candidates) {
            val s = supportOf(source, l)
            found[l] = s
            if (s.ready) return l
        }
        return candidates.firstOrNull { !found.getValue(it).unsupported } ?: SpeechLanguage.english
    }

    /** Auto's [language] turned out missing once listening began. */
    fun missed(language: SpeechLanguage) {
        missing.add(language)
    }

    /** Keeps [choice] for this phone; null goes back to Auto. */
    fun choose(choice: SpeechLanguage?) {
        missing.clear()
        if (choice == this.choice) return
        this.choice = choice
        if (choice == null) prefs.remove(SpeechLanguage.prefsKey) else prefs.setString(SpeechLanguage.prefsKey, choice.name)
        notifyListeners()
    }

    companion object {
        /** [SpeechSource.support], ready when the phone can't say (listening finds out). */
        suspend fun supportOf(source: SpeechSource, language: SpeechLanguage): SpeechCheck = try {
            source.support(language)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            SpeechCheck(SpeechStatus.ready)
        }
    }
}
