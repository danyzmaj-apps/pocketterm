package com.danyzmaj.pocketterm

import android.content.Intent
import android.content.pm.PackageManager
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import kotlinx.coroutines.CompletableDeferred
import java.lang.ref.WeakReference

/**
 * The activity in front, for what needs one: runtime permissions, the keep-awake flag, starting
 * Settings. [MainActivity] registers itself in onCreate ([attach]); the app has only that one.
 */
object ActivityHost {
    private var ref = WeakReference<ComponentActivity>(null)
    private var launcher: ActivityResultLauncher<String>? = null

    /** Waiting for the permission in flight's answer, by permission. */
    private val waiting = mutableMapOf<String, MutableList<CompletableDeferred<Boolean>>>()
    private var asking: String? = null

    val activity: ComponentActivity? get() = ref.get()

    /** Called from the activity's onCreate (before it's started, as registerForActivityResult needs). */
    fun attach(activity: ComponentActivity) {
        ref = WeakReference(activity)
        launcher = activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            val permission = asking ?: return@registerForActivityResult
            asking = null
            waiting.remove(permission)?.forEach { it.complete(granted) }
            // Another permission asked for meanwhile.
            waiting.keys.firstOrNull()?.let(::launch)
        }
    }

    fun detach(activity: ComponentActivity) {
        if (ref.get() !== activity) return
        ref = WeakReference(null)
        launcher = null
        asking = null
        waiting.values.flatten().forEach { it.complete(false) }
        waiting.clear()
    }

    /** Whether [permission] is granted, asking for it if it isn't yet (false without an activity). Main thread. */
    suspend fun request(permission: String): Boolean {
        val a = activity ?: return false
        if (a.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) return true
        if (launcher == null) return false
        val answer = CompletableDeferred<Boolean>()
        val list = waiting.getOrPut(permission) { mutableListOf() }
        list.add(answer)
        if (asking == null) launch(permission)
        return answer.await()
    }

    private fun launch(permission: String) {
        asking = permission
        launcher?.launch(permission)
    }

    /** Starts [intent] from the activity (or the app, as a new task); false if nothing handles it. */
    fun start(intent: Intent): Boolean {
        val a = activity
        return runCatching {
            if (a != null) {
                a.startActivity(intent)
            } else {
                PocketTermApp.instance.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }.isSuccess
    }
}
