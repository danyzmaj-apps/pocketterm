package com.danyzmaj.pocketterm.ui.setup

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.R
import com.danyzmaj.pocketterm.core.Backend
import com.danyzmaj.pocketterm.core.Session
import com.danyzmaj.pocketterm.core.appIconFor
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.LocalNav
import com.danyzmaj.pocketterm.ui.common.desktopDownloadsUrl
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.openExternal
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.theme.LocalStatus
import kotlinx.coroutines.launch

/** A sign-in from a scanned code under way; outlives the page, which goes while the scanner shows. */
private val signingIn = mutableStateOf(false)

/**
 * What a phone without a session shows: the only way in is the code PocketTerm on the computer
 * shows, scanned with this phone's camera, which connects to the server, signs in and brings that
 * computer's key. A phone never signs in with GitHub and never sets up a server. "Try the demo"
 * shows the app on a made-up computer instead. After a sign-out, a deleted account or a session the
 * server ended, it says why on top.
 */
@Composable
fun SetupScreen() {
    val graph = LocalGraph.current
    val nav = LocalNav.current
    val session = graph.session.observe()
    var busy by signingIn

    // Connects and signs in with the code the camera read; on failure the screen stays, with the
    // reason (authError) under the button. On the app's scope: this page leaves the composition while
    // the scanner is in front, which would cancel a coroutine of its own.
    fun scan() {
        graph.scope.launch {
            val link = nav.scan(signedIn = false) ?: return@launch
            busy = true
            try {
                session.connectLink(link, scanned = true)
            } finally {
                busy = false
            }
        }
    }

    Scaffold { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState()),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                Modifier
                    .widthIn(max = 460.dp)
                    .fillMaxWidth()
                    .padding(24.dp)
                    .animateContentSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                AppIcon()
                Spacer(Modifier.height(16.dp))
                Text(
                    "Welcome to PocketTerm",
                    style = MaterialTheme.typography.headlineSmall,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.semantics { heading() },
                )
                AnimatedVisibility(session.signedOutReason != null) {
                    Text(
                        session.signedOutReason ?: "",
                        color = LocalStatus.current.needs,
                        style = MaterialTheme.typography.bodyMedium,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 10.dp).tag("signed-out-reason"),
                    )
                }
                Spacer(Modifier.height(10.dp))
                Text(
                    "Your computer\u2019s coding sessions on your phone, end-to-end encrypted. This phone connects by " +
                        "scanning the code PocketTerm on your computer shows.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(24.dp))
                val link = session.linkToConfirm
                if (link != null) {
                    ConfirmLink(session, link)
                } else {
                    ScanSteps(busy = busy, onScan = ::scan)
                }
                val error = session.authError
                if (error != null) {
                    Text(
                        error,
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 12.dp).tag("auth-error"),
                    )
                }
                Spacer(Modifier.height(20.dp))
                OutlinedButton(
                    onClick = { session.enterDemo() },
                    enabled = !busy,
                    contentPadding = ButtonDefaults.ButtonWithIconContentPadding,
                    modifier = Modifier.fillMaxWidth().tag("try-demo"),
                ) {
                    Text("Try the demo", Modifier.padding(vertical = 6.dp))
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    "No computer yet? See PocketTerm with made-up sessions. Nothing connects.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

/** The app's icon for the chosen theme, as the launcher shows it (adaptive layers, rounded). */
@Composable
private fun AppIcon() {
    val choice by LocalGraph.current.appearance.choice.collectAsState()
    val (background, foreground) = when (appIconFor(choice)) {
        "dawn" -> R.drawable.ic_launcher_dawn_background to R.drawable.ic_launcher_dawn_foreground
        "tokyoNight" -> R.drawable.ic_launcher_tokyo_night_background to R.drawable.ic_launcher_tokyo_night_foreground
        else -> R.drawable.ic_launcher_background to R.drawable.ic_launcher_foreground
    }
    Box(Modifier.size(64.dp).clip(RoundedCornerShape(18.dp)), contentAlignment = Alignment.Center) {
        Image(painterResource(background), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        // An adaptive icon's layers are 108dp with the visible part the middle 72dp: 1.5 times what shows.
        Image(painterResource(foreground), null, Modifier.requiredSize(96.dp))
    }
}

/** How a phone gets in: numbered steps, where to get the computer's app, and the scan button. */
@Composable
private fun ScanSteps(busy: Boolean, onScan: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        OutlinedCard(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Step(1, "Install PocketTerm on your computer and open it. Its setup connects it to your server.")
                Step(2, "On the computer, open Settings \u2192 Add\u00A0a\u00A0phone\u2026 to show a code.")
                Step(3, "Tap the button below and point this phone at it.")
                Step(4, "That\u2019s it: the phone connects and signs in by itself.")
            }
        }
        // Step 1 needs PocketTerm on the computer: where to get it.
        TextButton(
            onClick = { openExternal(desktopDownloadsUrl) },
            contentPadding = ButtonDefaults.TextButtonWithIconContentPadding,
            modifier = Modifier.padding(top = 4.dp).tag("get-desktop"),
        ) {
            Icon(Icons.AutoMirrored.Filled.OpenInNew, null, Modifier.size(ButtonDefaults.IconSize))
            Spacer(Modifier.width(ButtonDefaults.IconSpacing))
            Text("Get PocketTerm for Mac or Windows")
        }
        Spacer(Modifier.height(8.dp))
        Button(
            onClick = onScan,
            enabled = !busy,
            contentPadding = ButtonDefaults.ButtonWithIconContentPadding,
            modifier = Modifier.fillMaxWidth().height(56.dp).tag("scan-code"),
        ) {
            if (busy) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                Icon(Icons.Filled.QrCodeScanner, null, Modifier.size(ButtonDefaults.IconSize))
                Spacer(Modifier.width(ButtonDefaults.IconSpacing))
                Text("Scan the code from your computer")
            }
        }
    }
}

@Composable
private fun Step(n: Int, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Surface(shape = CircleShape, color = MaterialTheme.colorScheme.secondaryContainer, modifier = Modifier.size(24.dp)) {
            Box(contentAlignment = Alignment.Center) {
                Text(
                    "$n",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f).padding(top = 2.dp))
    }
}

/**
 * A setup link from outside the app to another server ([Session.linkToConfirm]): nothing happens
 * until the person says yes. Anyone can send such a link, and this device's sessions would then go
 * through that server.
 */
@Composable
private fun ConfirmLink(session: Session, link: String) {
    val scope = rememberCoroutineScope()
    val host = Backend.fromLink(link)?.host ?: "?"
    OutlinedCard(
        Modifier.fillMaxWidth().tag("confirm-link"),
        border = BorderStroke(1.dp, LocalStatus.current.needs),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text("Connect to $host?", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp))
            Text(
                "A link asks to connect PocketTerm to this server. Only connect if you opened it yourself, from your own " +
                    "computer or server: your sessions and the images you send go through it.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(16.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(
                    onClick = { scope.launch { session.answerLink(connect = false) } },
                    modifier = Modifier.tag("confirm-link-cancel"),
                ) { Text("Cancel") }
                Spacer(Modifier.width(8.dp))
                Button(
                    onClick = { scope.launch { session.answerLink(connect = true) } },
                    modifier = Modifier.tag("confirm-link-connect"),
                ) { Text("Connect") }
            }
        }
    }
}
