package com.danyzmaj.pocketterm.state

import com.danyzmaj.pocketterm.core.jsonOf
import com.danyzmaj.pocketterm.core.long
import com.danyzmaj.pocketterm.core.str
import kotlinx.serialization.json.JsonObject

/** How the Terminal list orders its projects; [key] is what's kept (the Flutter app's `ProjectSort.name`). */
enum class ProjectSort(val key: String, val label: String) {
    /** A–Z by folder name; somewhere unknown last. */
    byName("name", "Name"),

    /** Most recent activity first, as last ranked. */
    activity("activity", "Recent activity"),
}

/**
 * The name and colour the person gave a row of the Terminal list (kept per computer and row key,
 * `pocketterm_tile_looks`); null where they haven't set one. [color] is ARGB, one of [tileColors].
 */
data class TileLook(val name: String? = null, val color: Long? = null) {
    fun withName(name: String?) = copy(name = name?.trim()?.ifEmpty { null })

    fun withColor(color: Long?) = copy(color = color)

    /** As the Flutter app kept it: `{name?, color?}`, the colour an ARGB int. */
    fun toJson(): JsonObject = jsonOf(*listOfNotNull(name?.let { "name" to it }, color?.let { "color" to it }).toTypedArray())

    companion object {
        fun fromJson(j: JsonObject) = TileLook(name = j["name"].str, color = j["color"].long)
    }
}

/** The colours a row can be tinted with: bright enough to read on light and dark backgrounds alike (ARGB). */
val tileColors: List<Long> = listOf(
    0xFFE5484D, 0xFFF76B15, 0xFFFFC53D, 0xFF46A758, 0xFF12A594, 0xFF0090FF, 0xFF8E4EC6, 0xFFD6409F,
)

/** What [tileColors] are called, in the same order: what TalkBack reads for each swatch. */
val tileColorNames: List<String> = listOf("Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink")
