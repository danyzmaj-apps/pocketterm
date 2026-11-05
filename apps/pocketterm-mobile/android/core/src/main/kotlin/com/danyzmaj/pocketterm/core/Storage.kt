package com.danyzmaj.pocketterm.core

/**
 * Per-device preferences, as Flutter's shared_preferences kept them: the app backs it with
 * SharedPreferences (migrating the old `flutter.<key>` entries once), tests with [MemoryPreferences].
 * Getters return null when the key is absent or holds another type.
 */
interface PreferenceStore {
    fun getString(key: String): String?
    fun setString(key: String, value: String)
    fun getBool(key: String): Boolean?
    fun setBool(key: String, value: Boolean)
    fun getInt(key: String): Long?
    fun setInt(key: String, value: Long)
    fun getStringList(key: String): List<String>?
    fun setStringList(key: String, value: List<String>)
    fun remove(key: String)
}

/** A [PreferenceStore] in memory: for tests, and before the real one is there. */
class MemoryPreferences(initial: Map<String, Any> = emptyMap()) : PreferenceStore {
    private val values = LinkedHashMap<String, Any>(initial)

    @Synchronized override fun getString(key: String) = values[key] as? String
    @Synchronized override fun setString(key: String, value: String) { values[key] = value }
    @Synchronized override fun getBool(key: String) = values[key] as? Boolean
    @Synchronized override fun setBool(key: String, value: Boolean) { values[key] = value }
    @Synchronized override fun getInt(key: String) = (values[key] as? Number)?.toLong()
    @Synchronized override fun setInt(key: String, value: Long) { values[key] = value }
    @Synchronized override fun getStringList(key: String) = (values[key] as? List<*>)?.filterIsInstance<String>()
    @Synchronized override fun setStringList(key: String, value: List<String>) { values[key] = value.toList() }
    @Synchronized override fun remove(key: String) { values.remove(key) }
}

/**
 * Secrets kept encrypted on the device (the app backs it with Keystore-wrapped storage). Item
 * names the Flutter app's native side used stay as they were, so an upgrade keeps them.
 */
interface SecureStore {
    suspend fun read(key: String): String?

    /** Null deletes it. */
    suspend fun write(key: String, value: String?)
}

/**
 * The preferences the Flutter app kept (shared_preferences on Android: the `FlutterSharedPreferences`
 * file, every key prefixed `flutter.`), read once into the native [PreferenceStore] under the same
 * keys without the prefix, so an upgrade keeps theme, sort, folded projects, voice language and the rest.
 */
object FlutterPreferences {
    /** The SharedPreferences file shared_preferences wrote. */
    const val FILE = "FlutterSharedPreferences"

    /** What shared_preferences put before every key. */
    const val PREFIX = "flutter."

    /** Set in the native store once the migration ran: it never runs again (a later Flutter value can't come back). */
    const val MIGRATED_KEY = "migratedFromFlutter"

    // shared_preferences_android's markers inside string values.
    private const val LIST_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"
    private const val JSON_LIST_PREFIX = "$LIST_PREFIX!"
    private const val DOUBLE_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu"
    private const val BIG_INTEGER_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBCaWdJbnRlZ2Vy"

    /**
     * One stored value as Dart read it: String, Boolean, Long, Double or List<String>; null for
     * what it can't be (a corrupt list). Lists are JSON after `<prefix>!` (newer plugin versions)
     * or a base64 Java-serialized list (older ones); a Set (older still) is a list.
     */
    fun decode(value: Any?): Any? = when (value) {
        is String -> when {
            value.startsWith(JSON_LIST_PREFIX) ->
                jsonDecodeOrNull(value.substring(JSON_LIST_PREFIX.length)).arr?.map { it.str ?: return null }
            value.startsWith(LIST_PREFIX) -> decodeJavaList(value.substring(LIST_PREFIX.length))
            value.startsWith(DOUBLE_PREFIX) -> value.substring(DOUBLE_PREFIX.length).toDoubleOrNull()
            value.startsWith(BIG_INTEGER_PREFIX) -> value.substring(BIG_INTEGER_PREFIX.length).toBigIntegerOrNull(Character.MAX_RADIX)?.toLong()
            else -> value
        }
        is Int -> value.toLong()
        is Long, is Boolean -> value
        is Float -> value.toDouble()
        is Set<*> -> value.filterIsInstance<String>()
        else -> null
    }

    private fun decodeJavaList(base64: String): List<String>? = try {
        java.io.ObjectInputStream(java.io.ByteArrayInputStream(java.util.Base64.getMimeDecoder().decode(base64))).use { s ->
            (s.readObject() as? List<*>)?.map { it as? String ?: return null }
        }
    } catch (_: Exception) {
        null
    }

    /**
     * Copies [flutter] (the Flutter file's entries, `SharedPreferences.getAll()`) into [into] once,
     * keys without [PREFIX]; entries without the prefix weren't Dart's and stay behind. Doubles have
     * no place in a [PreferenceStore] and PocketTerm kept none. The number of values copied; 0 when
     * it ran before.
     */
    fun migrate(flutter: Map<String, *>, into: PreferenceStore): Int {
        if (into.getBool(MIGRATED_KEY) == true) return 0
        var copied = 0
        for ((k, raw) in flutter) {
            if (!k.startsWith(PREFIX)) continue
            val key = k.substring(PREFIX.length)
            when (val v = decode(raw)) {
                is String -> into.setString(key, v)
                is Boolean -> into.setBool(key, v)
                is Long -> into.setInt(key, v)
                is List<*> -> into.setStringList(key, v.filterIsInstance<String>())
                else -> continue
            }
            copied++
        }
        into.setBool(MIGRATED_KEY, true)
        return copied
    }
}
