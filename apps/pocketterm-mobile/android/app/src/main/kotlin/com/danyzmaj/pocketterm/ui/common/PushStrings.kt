package com.danyzmaj.pocketterm.ui.common

import com.danyzmaj.pocketterm.core.Native
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/** Turned on, but the phone's Settings don't let PocketTerm notify. */
const val pushNotAllowed =
    "Notifications are off for PocketTerm in this phone’s Settings. Allow them there, then try again."

/** Turned on and allowed, but Google gave this phone no push address (no internet, or its service didn't answer). */
const val pushNoToken =
    "This phone couldn’t get a notification address from Apple or Google. Check its internet connection, then " +
        "try again."

/** On here, but turned off since in the phone's Settings: nothing shows. */
const val pushBlocked =
    "On, but notifications are off for PocketTerm in this phone’s Settings, so none show. Allow them there."

/** On here, but the server couldn't be reached to take this phone's token. */
const val pushNotSent =
    "On, but your server could not be reached to register this phone. PocketTerm tries again as soon as it can."

/**
 * Why turning push on didn't take: the phone's setting is off ([allowed] false: say so, with Settings
 * a tap away), else no push address came.
 */
fun Toaster.showPushNotAllowed(allowed: Boolean?, native: Native, scope: CoroutineScope) {
    if (allowed == false) {
        show(pushNotAllowed, action = "Settings") { scope.launch { native.openSettings(notifications = true) } }
    } else {
        show(pushNoToken, long = true)
    }
}
