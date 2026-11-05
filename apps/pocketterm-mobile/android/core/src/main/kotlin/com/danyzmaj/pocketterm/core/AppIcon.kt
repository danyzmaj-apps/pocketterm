package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * The app icon that goes with [choice]: `default` (the app's own icon, Catppuccin Mocha's) for
 * System and Catppuccin, else `dawn` (Rosé Pine) or `tokyoNight`, the alternates the native
 * sides know by these names.
 */
fun appIconFor(choice: ThemeChoice): String = when (choice) {
    ThemeChoice.system, ThemeChoice.catppuccin -> "default"
    ThemeChoice.rosePine -> "dawn"
    ThemeChoice.tokyoNight -> "tokyoNight"
}

/**
 * Keeps the app icon on [appearance]'s choice: [apply] gets [appIconFor]'s name now and after
 * each change of choice, in [scope]; a failing [apply] is logged, never breaking the theme
 * change. Returns what stops it.
 */
fun followAppIcon(appearance: Appearance, apply: suspend (String) -> Unit, scope: CoroutineScope): () -> Unit {
    val job = scope.launch {
        appearance.choice.map(::appIconFor).distinctUntilChanged().collect { icon ->
            launch {
                try {
                    apply(icon)
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    debugPrint("PocketTerm: app icon $icon: $e")
                }
            }
        }
    }
    return { job.cancel() }
}
