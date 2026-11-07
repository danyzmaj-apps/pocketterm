package com.danyzmaj.pocketterm.core

/** What the phone says once it forgot a Supabase project ([forgetSupabase]). */
const val SUPABASE_GONE_NOTE = "Your computer's PocketTerm now runs its own server. Scan its new code."

/**
 * PocketTerm no longer runs on Supabase projects: a phone whose saved server is one (a `supabase`
 * kind, or an older app's URL kept with the project's key) is signed out here, with no call to the
 * project: its server, sign-in and computer keys go, so it starts at setup. Any other server stays.
 * True when it forgot one.
 */
suspend fun forgetSupabase(native: Native): Boolean {
    if (native.getBackend()?.isSupabase != true) return false
    native.setBackend()
    native.setDeviceToken(null)
    native.removeAllChannelKeys()
    return true
}
