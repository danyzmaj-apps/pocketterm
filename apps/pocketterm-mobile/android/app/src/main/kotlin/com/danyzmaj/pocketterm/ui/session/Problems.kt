package com.danyzmaj.pocketterm.ui.session

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TooltipAnchorPosition
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import com.danyzmaj.pocketterm.core.TerminalException
import com.danyzmaj.pocketterm.ui.common.Toaster
import kotlinx.coroutines.CancellationException

/** What went wrong, as the phone says it: a terminal's own words, else the error's. */
fun problemText(e: Throwable): String = if (e is TerminalException) e.message else e.message ?: e.toString()

/** [block]'s result, or what went wrong; a cancellation (the page went) still cancels. */
suspend fun <T> attempt(block: suspend () -> T): Result<T> = try {
    Result.success(block())
} catch (e: CancellationException) {
    throw e
} catch (e: Exception) {
    Result.failure(e)
}

/**
 * A page's own snackbars, for a page with a bar at the bottom (a composer): its Scaffold shows them
 * above that bar, clear of what's typed, as the Flutter app's toasts kept above the composer.
 */
@Composable
fun rememberPageToaster(): Toaster {
    val scope = rememberCoroutineScope()
    return remember { Toaster(SnackbarHostState(), scope) }
}

/** [content] with a plain tooltip saying more about it, shown on a long press. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Hint(text: String, content: @Composable () -> Unit) {
    TooltipBox(
        positionProvider = TooltipDefaults.rememberTooltipPositionProvider(TooltipAnchorPosition.Above),
        tooltip = { PlainTooltip { Text(text) } },
        state = rememberTooltipState(),
    ) { content() }
}
