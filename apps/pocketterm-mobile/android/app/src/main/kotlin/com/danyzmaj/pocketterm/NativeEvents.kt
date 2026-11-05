package com.danyzmaj.pocketterm

import com.danyzmaj.pocketterm.core.NativeEvent
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Events for the app ([com.danyzmaj.pocketterm.core.Native.events]) from wherever they happen: the
 * activity, the push service, a followed session's notification. A tapped push's session also waits in
 * [tappedSession] until the app takes it, so one that launched the app isn't lost before anyone listens.
 */
object NativeEvents {
    private val flow = MutableSharedFlow<NativeEvent>(extraBufferCapacity = 64)

    val events: SharedFlow<NativeEvent> = flow.asSharedFlow()

    /** The session a tapped terminal push is about, until the app takes it. */
    @Volatile
    var tappedSession: String? = null

    fun emit(event: String, args: Map<String, Any?> = emptyMap()) {
        flow.tryEmit(NativeEvent(event, args))
    }
}
