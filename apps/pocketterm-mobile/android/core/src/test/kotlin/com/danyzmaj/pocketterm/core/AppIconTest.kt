package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals

class AppIconTest {
    // Unconfined: each change reaches apply before choose returns, as Dart's listeners do.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

    @AfterTest
    fun tearDown() = scope.cancel()

    @Test
    fun `the icon follows the picked theme, System and Catppuccin being the app's own`() {
        val appearance = Appearance().apply { load(MemoryPreferences(mapOf(Appearance.prefsKey to "tokyoNight"))) }
        val applied = mutableListOf<String>()
        val stop = followAppIcon(appearance, { applied.add(it) }, scope)

        // The kept choice's at launch.
        assertEquals(listOf("tokyoNight"), applied)
        appearance.choose(ThemeChoice.catppuccin)
        assertEquals(listOf("tokyoNight", "default"), applied)
        // System shows the same icon: nothing to change.
        appearance.choose(ThemeChoice.system)
        assertEquals(listOf("tokyoNight", "default"), applied)
        appearance.choose(ThemeChoice.rosePine)
        assertEquals(listOf("tokyoNight", "default", "dawn"), applied)

        stop()
        appearance.choose(ThemeChoice.tokyoNight)
        assertEquals(listOf("tokyoNight", "default", "dawn"), applied)
    }

    @Test
    fun `a fresh install keeps the app's own icon`() {
        val appearance = Appearance().apply { load(MemoryPreferences()) }
        val applied = mutableListOf<String>()
        followAppIcon(appearance, { applied.add(it) }, scope)
        assertEquals(listOf("default"), applied)
    }

    @Test
    fun `a platform without the switch does not break the theme change`() {
        val appearance = Appearance().apply { load(MemoryPreferences()) }
        followAppIcon(appearance, { throw UnsupportedOperationException("no icons here") }, scope)
        appearance.choose(ThemeChoice.rosePine)
        assertEquals(ThemeChoice.rosePine, appearance.choice.value)
    }
}
