package com.danyzmaj.pocketterm.ui.session

import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.ManagedActivityResultLauncher
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.core.ChatAttachment
import com.danyzmaj.pocketterm.core.ChatAttachments
import com.danyzmaj.pocketterm.core.ChatFile
import com.danyzmaj.pocketterm.core.ChatImage
import com.danyzmaj.pocketterm.core.PickedFile
import com.danyzmaj.pocketterm.core.formatBytes
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.tag
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max

/**
 * The composer's pending images and files, each with a ✕: a thumbnail per image, a chip with its name
 * and size per file, a spinner tile per one still loading, and why one was refused; nothing when empty.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AttachmentStrip(attachments: ChatAttachments, modifier: Modifier = Modifier, size: Dp = 56.dp) {
    attachments.observe()
    val items = attachments.items.toList()
    val problem = attachments.problem
    val loading = attachments.pending + if (attachments.picking) 1 else 0
    Column(modifier.fillMaxWidth().animateContentSize()) {
        if (items.isEmpty() && loading == 0 && problem == null) return@Column
        if (items.isNotEmpty() || loading > 0) {
            FlowRow(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(2.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                items.forEachIndexed { i, item ->
                    key(item) {
                        Removable(
                            label = when (item) {
                                is ChatImage -> "Remove image"
                                is ChatFile -> "Remove ${item.name}"
                            },
                            onRemove = { attachments.removeAt(i) },
                        ) { Attachment(item, size) }
                    }
                }
                repeat(loading) { i -> LoadingTile(size, Modifier.tag("attachment-loading-$i")) }
            }
        }
        if (problem != null) {
            Text(
                problem,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(top = 6.dp, bottom = 4.dp),
            )
        }
    }
}

/** Images and files as they went with a message: [AttachmentStrip]'s thumbnails and chips, without their ✕. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AttachmentThumbs(items: List<ChatAttachment>, modifier: Modifier = Modifier, size: Dp = 56.dp, end: Boolean = false) {
    FlowRow(
        modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp, if (end) Alignment.End else Alignment.Start),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        for (item in items) key(item) { Attachment(item, size) }
    }
}

@Composable
private fun Attachment(item: ChatAttachment, size: Dp) = when (item) {
    is ChatImage -> Thumb(item.bytes, size)
    is ChatFile -> FileChip(item, size)
}

/** A thumbnail or chip with its ✕ on the corner: a small dot, a 40 dp square catching the tap. */
@Composable
private fun Removable(label: String, onRemove: () -> Unit, content: @Composable () -> Unit) {
    Box {
        Box(Modifier.padding(top = 6.dp, end = 6.dp)) { content() }
        Box(
            Modifier
                .align(Alignment.TopEnd)
                .size(40.dp)
                .clickable(role = Role.Button, onClick = onRemove)
                .semantics { contentDescription = label },
            contentAlignment = Alignment.TopEnd,
        ) {
            Box(
                Modifier
                    .size(20.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surfaceContainerHighest)
                    .border(1.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.Close, contentDescription = null, modifier = Modifier.size(12.dp)) }
        }
    }
}

@Composable
private fun Thumb(bytes: ByteArray, size: Dp) {
    val px = with(LocalDensity.current) { size.roundToPx() }
    // Decoded small and off the main thread: a photo is megapixels.
    val image by produceState<ImageBitmap?>(null, bytes) { value = withContext(Dispatchers.Default) { thumbnail(bytes, px) } }
    val shape = RoundedCornerShape(8.dp)
    Box(
        Modifier
            .size(size)
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceContainerHigh)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, shape),
    ) {
        image?.let { Image(it, contentDescription = "Image", contentScale = ContentScale.Crop, modifier = Modifier.size(size)) }
    }
}

/** [bytes] decoded at about [px] (its shorter side), for a thumbnail; null when it isn't an image. */
private fun thumbnail(bytes: ByteArray, px: Int): ImageBitmap? {
    val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, o)
    if (o.outWidth <= 0 || o.outHeight <= 0) return null
    var sample = 1
    while (minOf(o.outWidth, o.outHeight) / (sample * 2) >= max(1, px)) sample *= 2
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
}

@Composable
private fun LoadingTile(size: Dp, modifier: Modifier) {
    val shape = RoundedCornerShape(8.dp)
    Box(
        modifier
            .padding(top = 6.dp, end = 6.dp)
            .size(size)
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceContainerHigh)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, shape)
            .semantics { contentDescription = "Loading image" },
        contentAlignment = Alignment.Center,
    ) { CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) }
}

/** A file as the composer holds it: an icon, its name and its size. */
@Composable
private fun FileChip(file: ChatFile, height: Dp) {
    val shape = RoundedCornerShape(8.dp)
    Row(
        Modifier
            .height(height)
            .widthIn(max = 200.dp)
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceContainerHigh)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, shape)
            .padding(start = 10.dp, end = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.AutoMirrored.Outlined.InsertDriveFile, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Column {
            Text(file.name, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(formatBytes(file.bytes.size.toLong()), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

// ---------------------------------------------------------------------- picking

/**
 * Where the composer's attachments come from: the system Photo Picker, the Files (SAF) picker and the
 * clipboard. Each hands what it reads to [attachments]; a cancelled picker leaves nothing behind.
 */
class AttachSources internal constructor(private val context: Context, private val attachments: ChatAttachments) {
    internal var photoLauncher: ManagedActivityResultLauncher<PickVisualMediaRequest, List<Uri>>? = null
    internal var fileLauncher: ManagedActivityResultLauncher<Array<String>, List<Uri>>? = null
    internal var photosPicked: CompletableDeferred<List<Uri>>? = null
    internal var filesPicked: CompletableDeferred<List<Uri>>? = null

    private val resolver: ContentResolver get() = context.contentResolver

    /** Photos from the Photo Picker. */
    suspend fun photos() {
        attachments.pick { _ ->
            val wait = CompletableDeferred<List<Uri>>()
            photosPicked = wait
            photoLauncher!!.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            val uris = wait.await()
            withContext(Dispatchers.IO) { uris.mapNotNull { read(it) } }
        }
    }

    /** Any files, from the Files picker: images among them go as images. */
    suspend fun files() {
        val wait = CompletableDeferred<List<Uri>>()
        filesPicked = wait
        fileLauncher!!.launch(arrayOf("*/*"))
        val uris = wait.await()
        if (uris.isEmpty()) return
        attachments.addFiles(withContext(Dispatchers.IO) { uris.map { UriFile(resolver, it) } })
    }

    /** The clipboard's images; false when it holds none. */
    suspend fun paste(): Boolean = attachments.paste {
        val clip = (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip
        val uris = if (clip == null) emptyList() else (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
        withContext(Dispatchers.IO) {
            uris.filter { resolver.getType(it)?.startsWith("image/") == true }.mapNotNull { read(it) }
        }
    }

    private fun read(uri: Uri): ByteArray? = resolver.openInputStream(uri)?.use { it.readBytes() }
}

/** A document the Files picker gave: its name and size as its provider says them. Built off the main thread. */
private class UriFile(private val resolver: ContentResolver, private val uri: Uri) : PickedFile {
    override val name: String
    override val mimeType: String? = resolver.getType(uri)
    private val size: Long?

    init {
        var n = ""
        var s: Long? = null
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 && !c.isNull(it) }?.let { n = c.getString(it) }
                c.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 && !c.isNull(it) }?.let { s = c.getLong(it) }
            }
        }
        name = n.ifEmpty { uri.lastPathSegment?.substringAfterLast('/') ?: "" }
        size = s
    }

    // A provider that doesn't say: read it, and the bytes tell.
    override suspend fun length(): Long = size ?: 0L

    override suspend fun readAsBytes(): ByteArray = withContext(Dispatchers.IO) {
        resolver.openInputStream(uri)?.use { it.readBytes() } ?: throw java.io.IOException("Couldn't open ${name.ifEmpty { "the file" }}.")
    }
}

/** The pickers for [attachments], registered with this activity. */
@Composable
fun rememberAttachSources(attachments: ChatAttachments): AttachSources {
    val context = LocalContext.current
    val sources = remember(attachments) { AttachSources(context, attachments) }
    // At most the room left, as the picker lets pick (it takes two or more).
    val limit = max(2, attachments.observe().room)
    val photos = remember(limit) { ActivityResultContracts.PickMultipleVisualMedia(limit) }
    sources.photoLauncher = rememberLauncherForActivityResult(photos) { uris ->
        sources.photosPicked?.complete(uris)
        sources.photosPicked = null
    }
    sources.fileLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        sources.filesPicked?.complete(uris)
        sources.filesPicked = null
    }
    return sources
}
