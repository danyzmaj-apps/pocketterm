package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resumeWithException

/** The HTTP clients PocketTerm makes, all from one base so they share its thread pool. */
object Http {
    /** The base every client is built from; the app may replace it before first use (e.g. to add an interceptor in tests). */
    @Volatile
    var base: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            val req = chain.request()
            // OkHttp offers permessage-deflate on every WebSocket, and the Dart server answers with
            // `client_max_window_bits=15`, which OkHttp refuses (it closes with 1010). Everything on
            // the live channel is sealed, so compression would gain next to nothing: none is asked
            // for. An application interceptor, since OkHttp skips network ones for WebSockets.
            if (req.header("Upgrade").equals("websocket", ignoreCase = true)) {
                chain.proceed(req.newBuilder().removeHeader("Sec-WebSocket-Extensions").build())
            } else {
                chain.proceed(req)
            }
        }
        .build()
}

/** Runs this call without blocking a thread; cancelling the coroutine cancels it. */
suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            if (cont.isActive) cont.resume(response) { _, r, _ -> r.close() } else response.close()
        }
    })
}
