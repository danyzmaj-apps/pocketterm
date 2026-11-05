package com.danyzmaj.pocketterm.ui.session

import android.content.ClipData
import android.os.Build
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.danyzmaj.pocketterm.ui.common.LocalToaster
import com.danyzmaj.pocketterm.ui.common.openExternal
import com.danyzmaj.pocketterm.ui.theme.LocalPalette
import com.danyzmaj.pocketterm.ui.theme.MonoFont
import com.mikepenz.markdown.compose.components.markdownComponents
import com.mikepenz.markdown.m3.Markdown
import com.mikepenz.markdown.m3.markdownColor
import com.mikepenz.markdown.m3.markdownTypography
import com.mikepenz.markdown.model.rememberMarkdownState
import kotlinx.coroutines.launch
import org.intellij.markdown.MarkdownTokenTypes
import org.intellij.markdown.ast.ASTNode
import org.intellij.markdown.ast.getTextInNode

/** Links in an answer open outside the app, in the browser; one that isn't a link opens nothing. */
private val browser = object : UriHandler {
    override fun openUri(uri: String) {
        try {
            openExternal(uri)
        } catch (_: Exception) {
            // Not a link anything here opens.
        }
    }
}

/**
 * An agent's answer: Markdown, its links opening in the browser, code blocks in the terminal theme's
 * colours and monospace, scrolling sideways, with a copy button. A line break in the answer is one on
 * screen, as the agent's terminal shows it.
 */
@Composable
fun MarkdownText(text: String, modifier: Modifier = Modifier) {
    val c = MaterialTheme.colorScheme
    val body = MaterialTheme.typography.bodyLarge.copy(fontSize = 15.sp, lineHeight = 1.5.em, color = c.onSurface)
    val inline = TextStyle(fontFamily = MonoFont, fontSize = 13.sp, color = c.onSurface)
    // Parsed here, at once: a transcript row that changes size a frame later would jump while scrolling.
    val state = rememberMarkdownState(text, immediate = true)
    val components = remember {
        markdownComponents(
            codeFence = { CodeBlock(fenceCode(it.content, it.node)) },
            codeBlock = { CodeBlock(indentedCode(it.content, it.node)) },
        )
    }
    CompositionLocalProvider(LocalUriHandler provides browser) {
        Markdown(
            markdownState = state,
            colors = markdownColor(
                text = c.onSurface,
                codeBackground = LocalPalette.current.termBg,
                inlineCodeBackground = c.surfaceContainerHighest,
                dividerColor = c.outlineVariant,
            ),
            typography = markdownTypography(
                text = body,
                paragraph = body,
                code = inline,
                inlineCode = inline,
                bullet = body,
                ordered = body,
                list = body,
            ),
            components = components,
            modifier = modifier.fillMaxWidth(),
        )
    }
}

/** A fenced block's code: its lines without the fences and the info string. */
private fun fenceCode(content: String, node: ASTNode): String {
    val kids = node.children
    val first = kids.indexOfFirst { it.type == MarkdownTokenTypes.CODE_FENCE_CONTENT }
    if (first < 0) return ""
    val last = kids.indexOfLast { it.type == MarkdownTokenTypes.CODE_FENCE_CONTENT }
    return buildString {
        for (k in kids.subList(first, last + 1)) {
            when (k.type) {
                MarkdownTokenTypes.CODE_FENCE_CONTENT -> append(k.getTextInNode(content))
                MarkdownTokenTypes.EOL -> append('\n')
            }
        }
    }
}

/** An indented block's code, without the indent. */
private fun indentedCode(content: String, node: ASTNode): String {
    val kids = node.children
    if (kids.isEmpty()) return ""
    return content.substring(kids.first().startOffset, kids.last().endOffset).trimIndent()
}

/** Code as a terminal shows it: the theme's colours, monospace, one line per line (it scrolls sideways), and Copy. */
@Composable
fun CodeBlock(code: String, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val clipboard = LocalClipboard.current
    val toaster = LocalToaster.current
    val scope = rememberCoroutineScope()
    Surface(
        color = p.termBg,
        contentColor = p.termFg,
        shape = RoundedCornerShape(12.dp),
        modifier = modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        Box {
            Text(
                code,
                fontFamily = MonoFont,
                fontSize = 12.5.sp,
                lineHeight = 1.4.em,
                softWrap = false,
                modifier = Modifier
                    .horizontalScroll(rememberScrollState())
                    .padding(start = 12.dp, top = 10.dp, end = 44.dp, bottom = 10.dp),
            )
            IconButton(
                onClick = {
                    scope.launch {
                        clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("code", code)))
                        // Android 13 and later confirm a copy themselves.
                        if (Build.VERSION.SDK_INT < 33) toaster.show("Copied")
                    }
                },
                modifier = Modifier.align(Alignment.TopEnd).size(40.dp),
            ) {
                Icon(Icons.Outlined.ContentCopy, contentDescription = "Copy code", tint = p.termDim, modifier = Modifier.size(18.dp))
            }
        }
    }
}
