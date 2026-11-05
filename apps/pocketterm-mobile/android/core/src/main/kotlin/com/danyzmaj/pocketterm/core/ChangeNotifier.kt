package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Dart's ChangeNotifier for the core's state holders: [revision] is a [StateFlow] that moves on
 * every [notifyListeners] (Compose collects it and reads the holder's properties), and plain
 * listeners serve code that isn't a coroutine.
 */
open class ChangeNotifier {
    private val _revision = MutableStateFlow(0L)
    private val listeners = CopyOnWriteArrayList<() -> Unit>()

    /** Moves on every change. */
    val revision: StateFlow<Long> = _revision.asStateFlow()

    fun addListener(listener: () -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: () -> Unit) {
        listeners.remove(listener)
    }

    protected fun notifyListeners() {
        _revision.value += 1
        for (l in listeners) l()
    }

    /** Drops the listeners; the holder isn't used after. */
    open fun dispose() {
        listeners.clear()
    }
}
