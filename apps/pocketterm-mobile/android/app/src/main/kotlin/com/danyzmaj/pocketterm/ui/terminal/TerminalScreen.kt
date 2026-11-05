package com.danyzmaj.pocketterm.ui.terminal

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.WrapText
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TooltipAnchorPosition
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.danyzmaj.pocketterm.core.TermCap
import com.danyzmaj.pocketterm.core.TermColors
import com.danyzmaj.pocketterm.core.TermScreen
import com.danyzmaj.pocketterm.core.TermState
import com.danyzmaj.pocketterm.core.TermWindow
import com.danyzmaj.pocketterm.core.TerminalException
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.state.HomeController
import com.danyzmaj.pocketterm.ui.LocalNav
import com.danyzmaj.pocketterm.ui.TerminalRoute
import com.danyzmaj.pocketterm.ui.common.CloseConfirm
import com.danyzmaj.pocketterm.ui.common.LocalToaster
import com.danyzmaj.pocketterm.ui.home.LinkNoteBar
import com.danyzmaj.pocketterm.ui.home.termError
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.rememberHaptics
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.home.termLabel
import com.danyzmaj.pocketterm.ui.theme.LocalPalette
import com.danyzmaj.pocketterm.ui.theme.MonoFont
import com.danyzmaj.pocketterm.ui.theme.argb
import kotlinx.coroutines.launch

/**
 * One terminal window: its screen as text, live, plus a composer and the keys a terminal program
 * needs (a coding agent's menus: arrows, Enter, Esc), each as far as the window's terminal allows.
 */
@Composable
fun TerminalScreen(route: TerminalRoute, home: HomeController) {
    home.observe()
    val remote = home.remote
    if (remote == null) {
        // The computer went (signed out of it, locked): nothing to show here.
        val nav = LocalNav.current
        LaunchedEffect(Unit) { nav.back() }
        return
    }
    TerminalPage(remote, route)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TerminalPage(remote: TerminalRemote, route: TerminalRoute) {
    remote.observe()
    val nav = LocalNav.current
    val toaster = LocalToaster.current
    val haptics = rememberHaptics()
    val scope = rememberCoroutineScope()
    val window = route.window
    // Without a watch the computer streams no screen.
    DisposableEffect(remote, window) {
        val unwatch = remote.watchWindow(window)
        onDispose { unwatch() }
    }
    KeepAwake()

    val w = remote.window(window)
    val online = remote.online
    // Listed once: missing from the list now, it closed.
    val seen = remember { booleanArrayOf(false) }
    if (w != null) seen[0] = true
    // Just launched: until the computer lists it, it's coming, not closed.
    val gone = online && !remote.fromCache && w == null && (seen[0] || !route.starting)
    val screen = remote.screen(window)
    val palette = LocalPalette.current
    val colors = remote.colors[window] ?: remember(palette) { themeColors(palette) }
    // A window not in the list yet (just launched) can do everything.
    fun can(c: TermCap) = w?.can(c) ?: true
    val readable = can(TermCap.read)
    val keys = can(TermCap.keys)
    val compose = can(TermCap.line) || can(TermCap.type)

    // A shell's long lines reflow to the phone's width; a full-screen program (a coding agent) lays
    // out to its own width, so its lines stay whole.
    var wrap by rememberSaveable { mutableStateOf(remote.window(window)?.agent == null) }
    var text by rememberSaveable { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var closing by remember { mutableStateOf(false) }
    val canSend = online && !gone && !sending && text.isNotBlank()

    fun send() {
        if (text.isBlank() || sending) return
        sending = true
        scope.launch {
            try {
                remote.send(window, text)
                text = ""
            } catch (e: Exception) {
                toaster.show(termError(e))
            }
            sending = false
        }
    }

    fun press(key: String) {
        haptics.picked()
        scope.launch {
            try {
                remote.press(window, key)
            } catch (e: Exception) {
                toaster.show(termError(e))
            }
        }
    }

    Scaffold(
        contentWindowInsets = WindowInsets(0),
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        if (w == null) "Terminal" else w.title.ifEmpty { w.program },
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = { nav.back() }) {
                        Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    if (w != null && online && w.can(TermCap.close)) {
                        Tooltipped("Close window") {
                            IconButton(onClick = { closing = true }, modifier = Modifier.tag("close-window")) {
                                Icon(Icons.Rounded.Close, contentDescription = "Close window")
                            }
                        }
                    }
                    if (readable) {
                        val label = if (wrap) "Don't wrap lines" else "Wrap lines"
                        Tooltipped(label) {
                            IconToggleButton(
                                checked = wrap,
                                onCheckedChange = { wrap = it },
                                modifier = Modifier.tag("wrap-lines"),
                            ) {
                                Icon(Icons.AutoMirrored.Rounded.WrapText, contentDescription = label)
                            }
                        }
                    }
                },
                // The theme's terminal bar, as the keys bar below: the page reads as one terminal, no
                // Material surface over the screen.
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = palette.termBar,
                    titleContentColor = palette.termFg,
                    navigationIconContentColor = palette.termFg,
                    actionIconContentColor = palette.termFg,
                ),
            )
        },
    ) { inner ->
        BoxWithConstraints(Modifier.padding(inner).fillMaxSize()) {
            val room = maxHeight
            Column(Modifier.fillMaxSize()) {
                Box(Modifier.animateContentSize()) { LinkNoteBar(remote) }
                SwitchBanner(remote, window)
                Box(
                    Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .background(argb(colors.background)),
                    contentAlignment = Alignment.Center,
                ) {
                    when {
                        gone -> Message("This window has closed.")
                        !readable && w != null -> Unreadable(remote, w)
                        screen == null ->
                            if (online) {
                                CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.dp, color = palette.accent)
                            } else {
                                Message("No screen yet.")
                            }
                        else -> ScreenText(screen, colors, wrap)
                    }
                }
                if (keys || compose) {
                    // Small room (keyboard up on a small phone, landscape, large text): the bar takes at
                    // most four fifths and scrolls, the composer last, instead of running off the screen.
                    KeysBar(
                        enabled = online && !gone,
                        keys = keys,
                        compose = compose,
                        text = text,
                        onText = { text = it },
                        canSend = canSend,
                        sending = sending,
                        onSend = ::send,
                        onPress = ::press,
                        modifier = Modifier.heightIn(max = room * .8f),
                    )
                } else {
                    Spacer(
                        Modifier
                            .fillMaxWidth()
                            .background(argb(colors.background))
                            .windowInsetsBottomHeight(WindowInsets.navigationBars),
                    )
                }
            }
        }
    }

    if (closing && w != null && online && !gone) {
        CloseConfirm(
            remote = remote,
            window = w.key,
            session = remote.sessions.firstOrNull { it.window == w.key }?.key,
            onDismiss = { closing = false },
            onClosed = {
                closing = false
                nav.back()
            },
        )
    }
}

/** An icon button's label shown on long-press, as Material does for icon buttons. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun Tooltipped(text: String, content: @Composable () -> Unit) {
    TooltipBox(
        positionProvider = TooltipDefaults.rememberTooltipPositionProvider(TooltipAnchorPosition.Below),
        tooltip = { PlainTooltip { Text(text) } },
        state = rememberTooltipState(),
    ) { content() }
}

@Composable
private fun Message(text: String) {
    Text(
        text,
        color = LocalPalette.current.termDim,
        textAlign = TextAlign.Center,
        modifier = Modifier.padding(32.dp),
    )
}

/** Why [w]'s screen doesn't show, and what would show it. */
@Composable
private fun Unreadable(remote: TerminalRemote, w: TermWindow) {
    val tmux = remote.observe().terminals.firstOrNull { it.id == "tmux" }
    val fix = if (tmux != null && tmux.state == TermState.missing) {
        tmux.note
    } else {
        "Sessions you start from the phone open in tmux, which can."
    }
    val p = LocalPalette.current
    Column(Modifier.padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            "${termLabel(w.app)} can't share its screen.",
            color = p.termFg,
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
            modifier = Modifier.tag("screen-unreadable"),
        )
        Spacer(Modifier.height(8.dp))
        Text(fix, color = p.termDim, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center)
    }
}

/** Lines whose styles are kept: a long-watched log would otherwise keep every line. */
private const val LINES_KEPT = 2000

/**
 * The screen's lines, bottom-anchored: its end shows first, and while the end is in view it follows
 * new lines; scrolled up, arriving lines don't move what's read. Unwrapped, it scrolls sideways.
 */
@Composable
private fun ScreenText(s: TermScreen, colors: TermColors, wrap: Boolean) {
    val style = TextStyle(
        fontFamily = MonoFont,
        fontSize = 12.sp,
        lineHeight = 14.4.sp,
        color = argb(colors.foreground),
    )
    val cache = remember(colors) { HashMap<String, AnnotatedString>() }
    fun line(l: String): AnnotatedString {
        if (cache.size >= LINES_KEPT) cache.clear()
        return cache.getOrPut(l) { ansiAnnotated(l, colors) }
    }

    val lines = s.lines
    val list = rememberLazyListState()
    // Whether the end is in view: set when a scroll ends, so lines arriving mid-scroll don't jump.
    var follow by remember { mutableStateOf(true) }
    LaunchedEffect(list) {
        snapshotFlow { list.isScrollInProgress }.collect { scrolling ->
            follow = !scrolling && list.firstVisibleItemIndex == 0 && list.firstVisibleItemScrollOffset == 0
        }
    }
    LaunchedEffect(s) { if (follow) list.scrollToItem(0) }

    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val width = if (wrap) {
            maxWidth
        } else {
            val widest = lines.maxOfOrNull { line(it).length } ?: 0
            val charPx = remember(measurer, style.fontSize) { measurer.measure("M", style).size.width }
            maxOf(maxWidth, with(density) { (charPx * widest).toDp() } + 24.dp)
        }
        val body = @Composable {
            SelectionContainer {
                LazyColumn(
                    state = list,
                    reverseLayout = true,
                    contentPadding = PaddingValues(vertical = 10.dp),
                    modifier = Modifier.width(width).fillMaxHeight(),
                ) {
                    // Reversed: item 0 is the last line. Keyed by the line's place since the phone first saw the
                    // window, so a line keeps its key as lines scroll off the top.
                    items(lines.size, key = { s.base + lines.size - 1 - it }) { i ->
                        Text(
                            line(lines[lines.size - 1 - i]),
                            style = style,
                            softWrap = wrap,
                            maxLines = if (wrap) Int.MAX_VALUE else 1,
                            modifier = Modifier.padding(horizontal = 10.dp),
                        )
                    }
                }
            }
        }
        if (wrap) {
            body()
        } else {
            Box(Modifier.fillMaxSize().horizontalScroll(rememberScrollState())) { body() }
        }
    }
}

/**
 * The keys a terminal program needs, if the window's terminal can press them, and the composer, if
 * it can type; in the theme's terminal colours, above the keyboard.
 */
@Composable
private fun KeysBar(
    enabled: Boolean,
    keys: Boolean,
    compose: Boolean,
    text: String,
    onText: (String) -> Unit,
    canSend: Boolean,
    sending: Boolean,
    onSend: () -> Unit,
    onPress: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val p = LocalPalette.current
    Surface(color = p.termBar, contentColor = p.termFg, modifier = modifier.fillMaxWidth()) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState(), reverseScrolling = true)
                .windowInsetsPadding(WindowInsets.ime.union(WindowInsets.navigationBars))
                .padding(start = 8.dp, end = 8.dp, top = 6.dp, bottom = 8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (keys && enabled) {
                Row(Modifier.fillMaxWidth()) {
                    Key("Esc", "Esc", "esc", onPress, Modifier.weight(1f))
                    Key("Tab", "Tab", "tab", onPress, Modifier.weight(1f))
                    Key("↑", "Up", "up", onPress, Modifier.weight(1f))
                    Key("↓", "Down", "down", onPress, Modifier.weight(1f))
                    Key("⏎", "Enter", "enter", onPress, Modifier.weight(1f))
                    Key("^C", "Control C", "ctrl+c", onPress, Modifier.weight(1f))
                }
            }
            if (compose) {
                Row(verticalAlignment = Alignment.Bottom) {
                    TextField(
                        value = text,
                        onValueChange = onText,
                        enabled = enabled,
                        placeholder = { Text("Type a line…") },
                        minLines = 1,
                        maxLines = 6,
                        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
                        shape = RoundedCornerShape(24.dp),
                        colors = TextFieldDefaults.colors(
                            focusedContainerColor = p.termBg,
                            unfocusedContainerColor = p.termBg,
                            disabledContainerColor = p.termBg,
                            focusedTextColor = p.termFg,
                            unfocusedTextColor = p.termFg,
                            disabledTextColor = p.termDim,
                            cursorColor = p.accent,
                            focusedIndicatorColor = Color.Transparent,
                            unfocusedIndicatorColor = Color.Transparent,
                            disabledIndicatorColor = Color.Transparent,
                            focusedPlaceholderColor = p.termDim,
                            unfocusedPlaceholderColor = p.termDim,
                            disabledPlaceholderColor = p.termDim,
                        ),
                        modifier = Modifier.weight(1f).tag("term-input"),
                    )
                    Spacer(Modifier.width(8.dp))
                    Tooltipped("Send (types it, then Enter)") {
                        FilledIconButton(
                            onClick = onSend,
                            enabled = canSend,
                            colors = IconButtonDefaults.filledIconButtonColors(
                                containerColor = p.accent,
                                contentColor = p.onAccent,
                                disabledContainerColor = p.termBg,
                                disabledContentColor = p.termDim,
                            ),
                            modifier = Modifier.padding(bottom = 4.dp).size(48.dp).tag("term-send"),
                        ) {
                            if (sending) {
                                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = p.termFg)
                            } else {
                                Icon(Icons.Rounded.ArrowUpward, contentDescription = "Send (types it, then Enter)")
                            }
                        }
                    }
                }
            }
        }
    }
}

/** One key cap: [label] on it, [name] for TalkBack, at least 48 dp to tap. */
@Composable
private fun Key(label: String, name: String, key: String, onPress: (String) -> Unit, modifier: Modifier) {
    val p = LocalPalette.current
    Surface(
        onClick = { onPress(key) },
        shape = RoundedCornerShape(10.dp),
        color = p.termBg,
        contentColor = p.termFg,
        border = BorderStroke(1.dp, p.termLine),
        modifier = modifier
            .padding(horizontal = 3.dp, vertical = 2.dp)
            .heightIn(min = 44.dp)
            .tag("key-$key")
            .semantics { contentDescription = name },
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(label, fontSize = 15.sp, modifier = Modifier.clearAndSetSemantics {})
        }
    }
}
