package com.danyzmaj.pocketterm.ui.terminal

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import com.danyzmaj.pocketterm.ui.LocalGraph
import kotlinx.coroutines.launch

/** How many screens want the display on; it goes off when the last one leaves. */
private var awake = 0

/**
 * Keeps the display on while it's in the composition: a terminal is something you watch. Counted,
 * so the list and a screen pushed over it can both ask without one's leaving turning it off for
 * the other during the page transition.
 */
@Composable
fun KeepAwake() {
    val graph = LocalGraph.current
    DisposableEffect(Unit) {
        if (awake++ == 0) graph.scope.launch { graph.native.setKeepAwake(true) }
        onDispose {
            if (--awake == 0) graph.scope.launch { graph.native.setKeepAwake(false) }
        }
    }
}
