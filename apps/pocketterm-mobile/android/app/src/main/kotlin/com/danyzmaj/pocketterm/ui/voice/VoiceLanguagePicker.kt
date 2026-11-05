package com.danyzmaj.pocketterm.ui.voice

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import com.danyzmaj.pocketterm.core.SpeechCheck
import com.danyzmaj.pocketterm.core.SpeechFix
import com.danyzmaj.pocketterm.core.SpeechLanguage
import com.danyzmaj.pocketterm.core.SpeechStatus
import com.danyzmaj.pocketterm.state.VoiceLanguage
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.theme.LocalStatus
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * Auto and each language, with what this phone has of it, asked on opening and on coming back to
 * the app: on the phone; to download (Download); to add in the phone's settings (Open Settings); or
 * not supported, which can't be picked. A tap keeps the choice for this phone.
 */
@Composable
fun VoiceLanguagePicker() {
    val graph = LocalGraph.current
    val source = graph.speech
    val voice = graph.voiceLanguage.observe()
    val scope = rememberCoroutineScope()
    val support = remember { mutableStateMapOf<SpeechLanguage, SpeechCheck>() }
    val fixing = remember { mutableStateMapOf<SpeechLanguage, Boolean>() }
    var auto by remember { mutableStateOf<SpeechLanguage?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun refresh() {
        val found = SpeechLanguage.entries.associateWith { VoiceLanguage.supportOf(source, it) }
        val a = voice.auto(source)
        support.clear()
        support.putAll(found)
        auto = a
    }

    // Asked on opening, and on coming back from the phone's settings or its download: what it has may have changed.
    DisposableEffect(Unit) {
        val observer = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_START) scope.launch { refresh() } }
        val lifecycle = ProcessLifecycleOwner.get().lifecycle
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    fun fix(l: SpeechLanguage, fix: SpeechFix) {
        fixing[l] = true
        error = null
        scope.launch {
            try {
                source.fix(fix, l)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.message ?: e.toString()
            }
            fixing.remove(l)
            refresh()
        }
    }

    val choice = voice.choice
    val c = MaterialTheme.colorScheme

    @Composable
    fun mark(on: Boolean) = Box(Modifier.width(24.dp)) {
        if (on) Icon(Icons.Rounded.Check, contentDescription = null, tint = c.primary)
    }

    Column(Modifier.fillMaxWidth()) {
        ListItem(
            modifier = Modifier.tag("voice-language-auto").clickable { voice.choose(null) },
            leadingContent = { mark(choice == null) },
            headlineContent = { Text("Auto") },
            supportingContent = {
                Text("The phone’s language when it has it, else English${auto?.let { ": now ${it.label}" } ?: ""}")
            },
            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        )
        for (l in SpeechLanguage.entries) {
            val s = support[l]
            val unsupported = s?.unsupported ?: false
            val note: String?
            var action: (@Composable () -> Unit)? = null
            when {
                s == null -> note = null
                fixing[l] == true -> {
                    note = "Downloading…"
                    action = { CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) }
                }
                s.status == SpeechStatus.ready -> note = "On this phone"
                s.status == SpeechStatus.downloading -> note = "Downloading…"
                s.status == SpeechStatus.noLanguage && s.fix == SpeechFix.download -> {
                    note = "Not downloaded yet"
                    action = {
                        TextButton(onClick = { fix(l, SpeechFix.download) }, modifier = Modifier.tag("voice-language-${l.name}-download")) {
                            Text("Download")
                        }
                    }
                }
                s.status == SpeechStatus.noLanguage && s.fix != null -> {
                    val f = s.fix!!
                    note = "Add it in the phone’s speech settings"
                    action = {
                        TextButton(onClick = { fix(l, f) }, modifier = Modifier.tag("voice-language-${l.name}-${f.name}")) {
                            Text("Open Settings")
                        }
                    }
                }
                else -> note = "Not supported on this phone"
            }
            ListItem(
                modifier = Modifier
                    .tag("voice-language-${l.name}")
                    .clickable(enabled = !unsupported) { voice.choose(l) }
                    .alpha(if (unsupported) .5f else 1f),
                leadingContent = { mark(choice == l) },
                headlineContent = { Text(l.label) },
                supportingContent = note?.let { { Text(it) } },
                trailingContent = action,
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            )
        }
        error?.let {
            Text(
                it,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
                style = MaterialTheme.typography.bodyMedium,
                color = LocalStatus.current.needs,
            )
        }
    }
}
