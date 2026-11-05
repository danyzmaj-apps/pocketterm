package com.danyzmaj.pocketterm.ui.session

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.StopCircle
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.core.LiveCommand
import com.danyzmaj.pocketterm.core.LiveSummary
import com.danyzmaj.pocketterm.core.TermCap
import com.danyzmaj.pocketterm.core.matchCommands
import com.danyzmaj.pocketterm.state.Tip
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.queue.MenuRow
import com.danyzmaj.pocketterm.ui.tips.TipAnchor
import com.danyzmaj.pocketterm.ui.voice.VoiceMic

/**
 * The bar under the transcript: slash-command suggestions, Continue after a restart, the queue, Queue and
 * Stop while the agent works, the attachments, and the field with Attach, the microphone and Send.
 * [online]: prompts can go now.
 */
@Composable
fun Composer(model: SessionModel, s: LiveSummary?, title: String, online: Boolean, sources: AttachSources) {
    val attachments = model.attachments.observe()
    val busy = s?.busy ?: false
    val agent = model.agent(s)
    val text = model.field.text
    // One at a time, in order: the next waits until the computer has the one sending. While images load,
    // the button stays a disabled Send.
    val loading = attachments.loading
    val canSend = online && !model.sending && !model.delivering && !loading && (text.trim().isNotEmpty() || !attachments.isEmpty)
    // Nothing to send: the button there is the microphone.
    val talk = !model.sending && !loading && text.trim().isEmpty() && attachments.isEmpty
    val canAttach = online && attachments.room > 0 && !loading
    val slash = text.startsWith("/")
    val commanding = online && s != null && slash
    val noWindow = commanding && !model.can(model.windowKey(s), TermCap.line)
    val matches = if (commanding && !noWindow) matchCommands(s.commands, text) else emptyList()

    Column(Modifier.fillMaxWidth().padding(start = 8.dp, top = 6.dp, end = 8.dp, bottom = 8.dp)) {
        if (noWindow) {
            Text(
                noCommands(agent),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 12.dp, top = 2.dp, end = 12.dp, bottom = 6.dp).tag("commands-need-window"),
            )
        }
        for (c in matches) CommandRow(c) { model.complete(c) }
        AnimatedVisibility(model.continueOffer && online && s != null && !busy, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
            Hint("Carry on with what it was doing") {
                AssistChip(
                    onClick = { model.sendContinue() },
                    label = { Text("Continue") },
                    leadingIcon = { Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.size(AssistChipDefaults.IconSize)) },
                    modifier = Modifier.padding(start = 4.dp, bottom = 4.dp).tag("continue"),
                )
            }
        }
        QueueStrip(model.remote, model.key, s, online, steers = agent.steers)
        AnimatedVisibility(busy && online, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
            Row(Modifier.fillMaxWidth().padding(start = 4.dp, bottom = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                // An agent that can't steer queues every prompt while busy.
                if (agent.steers) {
                    TipAnchor(Tip.queue) {
                        Hint("Off: the prompt steers ${agent.label} now") {
                            FilterChip(
                                selected = model.followUp,
                                onClick = { model.followUp = !model.followUp },
                                label = { Text("Queue") },
                                leadingIcon = if (model.followUp) {
                                    { Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(FilterChipDefaults.IconSize)) }
                                } else {
                                    null
                                },
                                modifier = Modifier.tag("follow-up"),
                            )
                        }
                    }
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = { model.stop() }, enabled = !model.stopping, modifier = Modifier.tag("stop")) {
                    Icon(Icons.Outlined.StopCircle, contentDescription = null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("Stop", color = MaterialTheme.colorScheme.error)
                }
            }
        }
        AttachmentStrip(attachments, Modifier.padding(horizontal = 8.dp))
        Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.Bottom) {
            AttachMenu(enabled = canAttach) { model.attach(sources, it) }
            TipAnchor(Tip.slash, Modifier.weight(1f)) {
                TextField(
                    value = model.field,
                    onValueChange = { model.field = it },
                    enabled = online,
                    minLines = 1,
                    maxLines = 6,
                    placeholder = {
                        Text(
                            if (busy) {
                                if (model.followUp || !agent.steers) "Queue a prompt…" else "Steer ${agent.label}…"
                            } else {
                                "Prompt ${agent.label}…"
                            },
                        )
                    },
                    // A command's name isn't a word to correct or capitalize.
                    keyboardOptions = KeyboardOptions(
                        capitalization = if (slash) KeyboardCapitalization.None else KeyboardCapitalization.Sentences,
                        autoCorrectEnabled = !slash,
                    ),
                    shape = RoundedCornerShape(24.dp),
                    colors = TextFieldDefaults.colors(
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                        disabledIndicatorColor = Color.Transparent,
                    ),
                    modifier = Modifier
                        .fillMaxWidth()
                        .focusRequester(model.focus)
                        // A hardware keyboard's Tab takes the first suggestion.
                        .onPreviewKeyEvent { e ->
                            if (e.type == KeyEventType.KeyDown && e.key == Key.Tab && matches.isNotEmpty()) {
                                model.complete(matches.first())
                                true
                            } else {
                                false
                            }
                        }
                        .tag("session-input"),
                )
            }
            // A command's name isn't spoken; otherwise a smaller microphone beside Send adds to what's typed. It
            // slides in as the first letter is typed, making room instead of shoving the field over.
            AnimatedVisibility(
                !talk && !model.sending && online && !slash,
                enter = expandHorizontally() + fadeIn() + scaleIn(initialScale = .7f),
                exit = shrinkHorizontally() + fadeOut() + scaleOut(targetScale = .7f),
            ) {
                VoiceMic(existing = text, title = title, onResult = model::voiced, small = true, modifier = Modifier.padding(start = 4.dp))
            }
            // The microphone turns into Send as something is typed, and back once it's cleared.
            Box(Modifier.padding(start = 4.dp, bottom = 4.dp)) {
                Crossfade(talk, label = "send") { mic ->
                    when {
                        mic && online -> VoiceMic(existing = text, title = title, onResult = model::voiced)
                        mic -> IconButton(onClick = {}, enabled = false, modifier = Modifier.tag("session-mic")) {
                            Icon(Icons.Filled.Mic, contentDescription = "Voice prompt")
                        }
                        else -> FilledIconButton(
                            onClick = { model.send(busy) },
                            enabled = canSend,
                            modifier = Modifier.tag("session-send").semantics { contentDescription = "Send" },
                        ) {
                            if (model.sending) {
                                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                            } else {
                                Icon(Icons.AutoMirrored.Filled.Send, contentDescription = null)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** A slash command to complete: its name, then what it does. */
@Composable
private fun CommandRow(c: LiveCommand, onPick: () -> Unit) {
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    Text(
        buildAnnotatedString {
            withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append("/${c.name}") }
            if (c.description.isNotEmpty()) withStyle(SpanStyle(color = dim)) { append("  ${c.description}") }
        },
        style = MaterialTheme.typography.bodyMedium,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onPick)
            .padding(horizontal = 12.dp, vertical = 10.dp)
            .tag("command-${c.name}"),
    )
}

/** Attach: paste an image, pick photos or files. */
@Composable
private fun AttachMenu(enabled: Boolean, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box(Modifier.padding(bottom = 4.dp)) {
        IconButton(onClick = { open = true }, enabled = enabled, modifier = Modifier.tag("attach")) {
            Icon(Icons.Filled.AttachFile, contentDescription = "Attach images or files")
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            val pick: (String) -> Unit = {
                open = false
                onPick(it)
            }
            MenuRow("Paste image", Icons.Filled.ContentPaste) { pick("paste") }
            MenuRow("Choose from Photos", Icons.Outlined.PhotoLibrary) { pick("photos") }
            MenuRow("Choose from Files", Icons.Outlined.FolderOpen) { pick("files") }
        }
    }
}
