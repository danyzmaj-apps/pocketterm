package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CancellationException
import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** How many images and files one message to a session takes. */
const val maxChatAttachments: Int = 10

/** The largest file a message takes: sealed, it's the most the server holds (20 MB). */
const val maxChatFileBytes: Int = Server.maxBlobBytes - sealedOverhead

/** The longest side an image is sent at: plenty for reading a screenshot, and it keeps uploads and the model's image tokens small. */
const val maxImageSide: Int = 2048

/** An image this small (and within [maxImageSide]) in a type every model reads is sent as it is. */
const val keepAsIsMaxBytes: Int = 4 shl 20

/** Something a message takes along: a [ChatImage] or a [ChatFile]. Compared by identity, as in Dart. */
sealed class ChatAttachment

/** An image about to be sent: its bytes and their type. */
class ChatImage(
    val bytes: ByteArray,
    /** image/png, image/jpeg, image/gif or image/webp. */
    val mime: String,
) : ChatAttachment()

/** A file about to be sent as it is (a document, an archive): the agent gets it under [name], as a file on the computer. */
class ChatFile(val name: String, val bytes: ByteArray, val mime: String) : ChatAttachment()

/** Picked files with these extensions go as images, scaled down like photos. */
val imageExtensions: Set<String> = setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp")

/** [bytes] for people: `512 bytes`, `3.4 KB`, `12.0 MB`. */
fun formatBytes(bytes: Long): String = when {
    bytes < 1024 -> "$bytes bytes"
    bytes < 1024 * 1024 -> "${fixed1(bytes / 1024.0)} KB"
    else -> "${fixed1(bytes / (1024.0 * 1024.0))} MB"
}

// Dart's toStringAsFixed(1): the exact value of the double, a tie rounding up.
private fun fixed1(x: Double): String = BigDecimal(x).setScale(1, RoundingMode.HALF_UP).toPlainString()

/** Decodes and scales images: the platform's codec (Android's BitmapFactory/ImageDecoder), which the app provides. */
interface ImageCodec {
    /** The pixel size of [raw]; null when it isn't an image the platform reads. */
    suspend fun size(raw: ByteArray): Pair<Int, Int>?

    /** [raw] decoded, scaled to [width]×[height] and encoded as PNG; null when that fails. */
    suspend fun toPng(raw: ByteArray, width: Int, height: Int): ByteArray?
}

/**
 * [raw] as an image to send: kept as it is when it's a PNG, JPEG, GIF or WebP no bigger than
 * [maxImageSide] and 4 MB, else decoded, scaled down to fit and re-encoded as PNG (which also
 * turns TIFF, HEIC and the like into something every model reads). Null when it isn't an image.
 */
suspend fun prepareChatImage(raw: ByteArray, codec: ImageCodec): ChatImage? {
    val (w, h) = try {
        codec.size(raw)
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    } ?: return null
    val mime = sniffImageType(raw)
    if (mime != null && max(w, h) <= maxImageSide && raw.size <= keepAsIsMaxBytes) return ChatImage(raw, mime)
    val scale = min(1.0, maxImageSide.toDouble() / max(w, h))
    val png = codec.toPng(raw, max(1, (w * scale).roundToInt()), max(1, (h * scale).roundToInt())) ?: return null
    return ChatImage(png, "image/png")
}

/** The type a model accepts, from the file's first bytes; null for others. */
fun sniffImageType(b: ByteArray): String? {
    fun at(i: Int, vararg sig: Int): Boolean {
        if (b.size < i + sig.size) return false
        return sig.indices.all { (b[i + it].toInt() and 0xff) == sig[it] }
    }
    return when {
        at(0, 0x89, 0x50, 0x4E, 0x47) -> "image/png"
        at(0, 0xFF, 0xD8, 0xFF) -> "image/jpeg"
        at(0, 0x47, 0x49, 0x46, 0x38) -> "image/gif"
        at(0, 0x52, 0x49, 0x46, 0x46) && at(8, 0x57, 0x45, 0x42, 0x50) -> "image/webp"
        else -> null
    }
}

/** A file the person picked (a SAF document): the app reads it. */
interface PickedFile {
    /** Its display name; may be empty. */
    val name: String

    /** Its type as the provider says; null or empty when it doesn't. */
    val mimeType: String?

    suspend fun length(): Long

    suspend fun readAsBytes(): ByteArray
}

/**
 * The images and files a composer holds until the message is sent, at most [maxChatAttachments],
 * in the order they came. Images load through [prepareChatImage]; files go as they are, up to
 * [maxChatFileBytes] each. Errors (not an image, too many, too large) go to [problem] for the
 * composer to show. While images load, [loading] is true and [pending] counts those not ready yet;
 * each joins [items] as soon as it is. Picking itself (photo picker, clipboard, documents) is the app's.
 */
class ChatAttachments(private val codec: ImageCodec) : ChangeNotifier() {
    val items: MutableList<ChatAttachment> = mutableListOf()

    var problem: String? = null
        private set

    /** True from the moment the photo picker opens until it hands back its files. */
    var picking: Boolean = false
        private set

    /** Images and files taken in but not ready yet. */
    var pending: Int = 0
        private set

    val isEmpty: Boolean get() = items.isEmpty()
    val loading: Boolean get() = picking || pending > 0
    val room: Int get() = maxChatAttachments - items.size - pending

    suspend fun addAll(raws: List<ByteArray>) {
        problem = null
        val take = min(raws.size, maxChatAttachments - items.size)
        if (raws.size > take) problem = TOO_MANY
        pending = take
        notifyListeners()
        var skipped = 0
        try {
            for (raw in raws.take(take)) {
                val image = prepareChatImage(raw, codec)
                if (image == null) skipped++ else items.add(image)
                pending--
                notifyListeners()
            }
            if (skipped > 0 && problem == null) {
                problem = if (skipped == 1) "That isn't an image PocketTerm can read." else "$skipped files aren't images."
            }
        } finally {
            pending = 0
            notifyListeners()
        }
    }

    /**
     * Adds files picked from the phone's files. Images among them (by their extension or their
     * first bytes) go as images; a file over [maxChatFileBytes] is left out, and said so.
     */
    suspend fun addFiles(files: List<PickedFile>) {
        problem = null
        val take = min(files.size, maxChatAttachments - items.size)
        if (files.size > take) problem = TOO_MANY
        pending = take
        notifyListeners()
        val tooLarge = mutableListOf<String>()
        try {
            for (f in files.take(take)) {
                addFile(f, tooLarge)
                pending--
                notifyListeners()
            }
            if (tooLarge.isNotEmpty() && problem == null) {
                val most = "files can be up to ${maxChatFileBytes / (1000 * 1000)} MB"
                problem = if (tooLarge.size == 1) "\"${tooLarge.single()}\" is too large: $most." else "${tooLarge.size} files are too large: $most."
            }
        } finally {
            pending = 0
            notifyListeners()
        }
    }

    /** Adds [f] to [items], or its name to [tooLarge]. */
    private suspend fun addFile(f: PickedFile, tooLarge: MutableList<String>) {
        val name = f.name.ifEmpty { "file" }
        val named = fileExtension(name) in imageExtensions
        if (!named && f.length() > maxChatFileBytes) {
            tooLarge.add(name)
            return
        }
        val bytes = f.readAsBytes()
        val image = if (named || sniffImageType(bytes) != null) prepareChatImage(bytes, codec) else null
        when {
            image != null -> items.add(image)
            bytes.size > maxChatFileBytes -> tooLarge.add(name)
            else -> {
                val mime = f.mimeType
                items.add(ChatFile(name, bytes, if (mime.isNullOrEmpty()) fileMime(name) else mime))
            }
        }
    }

    /** Pastes the clipboard's images ([clipboardImages]); false if it holds none (a text paste then goes ahead as usual). */
    suspend fun paste(clipboardImages: suspend () -> List<ByteArray>): Boolean {
        val raws = clipboardImages()
        if (raws.isEmpty()) return false
        addAll(raws)
        return true
    }

    /**
     * Picks photos with [picker] (given how many fit, [room]; it reads them); [picking] shows a
     * placeholder until the picker hands them back. A cancelled picker leaves nothing behind.
     */
    suspend fun pick(picker: suspend (limit: Int) -> List<ByteArray>) {
        picking = true
        notifyListeners()
        val raws = try {
            if (room <= 0) emptyList() else picker(room)
        } finally {
            picking = false
            notifyListeners()
        }
        addAll(raws)
    }

    fun removeAt(i: Int) {
        items.removeAt(i)
        problem = null
        notifyListeners()
    }

    /** Takes out [sent] (the ones a message took), keeping what came since. */
    fun removeSent(sent: Iterable<ChatAttachment>) {
        val gone = sent.toSet()
        items.removeAll { it in gone }
        notifyListeners()
    }

    private companion object {
        val TOO_MANY = "At most $maxChatAttachments images and files per message."
    }
}
