package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.nio.ByteBuffer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** A PNG as far as [FakeCodec] reads it: the PNG signature, then the width and height. */
private fun png(w: Int, h: Int): ByteArray =
    ByteBuffer.allocate(16).put(byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)).putInt(w).putInt(h).array()

/** Stands in for the platform's codec (dart:ui in the Dart tests): reads [png]'s size, "scales" by making another. */
private object FakeCodec : ImageCodec {
    override suspend fun size(raw: ByteArray): Pair<Int, Int>? {
        if (raw.size != 16 || sniffImageType(raw) != "image/png") return null
        val b = ByteBuffer.wrap(raw, 8, 8)
        return b.int to b.int
    }

    override suspend fun toPng(raw: ByteArray, width: Int, height: Int): ByteArray = png(width, height)
}

private suspend fun sizeOf(bytes: ByteArray): Pair<Int, Int>? = FakeCodec.size(bytes)

private class Picked(
    override val name: String,
    private val bytes: ByteArray,
    private val len: Long? = null,
    private val gate: CompletableDeferred<Unit>? = null,
) : PickedFile {
    override val mimeType: String? = null
    override suspend fun length(): Long = len ?: bytes.size.toLong()
    override suspend fun readAsBytes(): ByteArray {
        gate?.await()
        return bytes
    }
}

class ChatImagesTest {
    @Test
    fun `a small image is sent as it is`() = runTest {
        val raw = png(maxImageSide, 300)
        val image = prepareChatImage(raw, FakeCodec)!!
        assertEquals("image/png", image.mime)
        assertSame(raw, image.bytes)
    }

    @Test
    fun `a big image is scaled to fit, keeping its shape`() = runTest {
        val image = prepareChatImage(png(3000, 1000), FakeCodec)!!
        assertEquals("image/png", image.mime)
        assertEquals(2048 to 683, sizeOf(image.bytes))
    }

    @Test
    fun `a tall image is scaled by its height`() = runTest {
        val image = prepareChatImage(png(500, 4096), FakeCodec)!!
        assertEquals(250 to 2048, sizeOf(image.bytes))
    }

    @Test
    fun `something that is not an image is refused`() = runTest {
        assertNull(prepareChatImage("hello, not a picture".toByteArray(), FakeCodec))
    }

    @Test
    fun `image types are told by their first bytes`() {
        fun b(vararg x: Int) = ByteArray(x.size) { x[it].toByte() }
        assertEquals("image/png", sniffImageType(b(0x89, 0x50, 0x4E, 0x47, 0x0D)))
        assertEquals("image/jpeg", sniffImageType(b(0xFF, 0xD8, 0xFF, 0xE0)))
        assertEquals("image/gif", sniffImageType("GIF89a".toByteArray()))
        assertEquals("image/webp", sniffImageType("RIFF\u0000\u0000\u0000\u0000WEBPVP8 ".toByteArray()))
        assertNull(sniffImageType("RIFF\u0000\u0000\u0000\u0000WAVEfmt ".toByteArray()))
        assertNull(sniffImageType(b(0x49, 0x49, 0x2A, 0x00)), "TIFF gets re-encoded")
    }

    @Test
    fun `a picked document goes as a file, a picked picture as an image, in the order they came`() = runTest {
        val a = ChatAttachments(FakeCodec)
        a.addFiles(listOf(Picked("notes.pdf", "%PDF-1.7".toByteArray()), Picked("shot.png", png(40, 30)), Picked("README", "plain words".toByteArray())))
        assertNull(a.problem)
        assertEquals(3, a.items.size)
        assertIs<ChatFile>(a.items[0])
        assertIs<ChatImage>(a.items[1])
        assertIs<ChatFile>(a.items[2])
        val pdf = a.items.first() as ChatFile
        assertEquals(Triple("notes.pdf", "application/pdf", "%PDF-1.7"), Triple(pdf.name, pdf.mime, String(pdf.bytes)))
        assertEquals("application/octet-stream", (a.items.last() as ChatFile).mime)
    }

    @Test
    fun `a file over 20 MB is left out and said so - the others still come`() = runTest {
        val a = ChatAttachments(FakeCodec)
        a.addFiles(listOf(Picked("huge.zip", byteArrayOf(1, 2, 3), len = maxChatFileBytes + 1L), Picked("small.txt", "ok".toByteArray())))
        assertEquals(listOf("small.txt"), a.items.map { (it as ChatFile).name })
        assertEquals("\"huge.zip\" is too large: files can be up to 20 MB.", a.problem)

        a.addFiles(listOf(Picked("exactly.bin", byteArrayOf(0), len = maxChatFileBytes.toLong())))
        assertNull(a.problem, "the most that, sealed, still fits the server")
        assertEquals(2, a.items.size)
    }

    @Test
    fun `a message takes 10 images and files together, no more`() = runTest {
        val a = ChatAttachments(FakeCodec)
        val image = png(20, 20)
        a.addAll(List(4) { image })
        a.addFiles(List(8) { Picked("doc$it.txt", "x".toByteArray()) })
        assertEquals(10, a.items.size)
        assertEquals(4, a.items.filterIsInstance<ChatImage>().size)
        assertEquals(0, a.room)
        assertEquals("At most 10 images and files per message.", a.problem)

        a.addAll(listOf(image))
        assertEquals(10, a.items.size)
        assertEquals("At most 10 images and files per message.", a.problem)

        // Sent: what came meanwhile stays.
        a.removeSent(a.items.take(9).toList())
        assertEquals(listOf("doc5.txt"), a.items.map { (it as ChatFile).name })
    }

    @Test
    fun `images join one at a time, each counted as pending until it does`() = runTest {
        val a = ChatAttachments(FakeCodec)
        val image = png(20, 20)
        val seen = mutableListOf<Pair<Int, Int>>()
        var roomAtStart: Int? = null
        a.addListener {
            seen.add(a.items.size to a.pending)
            if (roomAtStart == null) roomAtStart = a.room
        }
        a.addAll(listOf(image, image, image))
        assertEquals(listOf(0 to 3, 1 to 2, 2 to 1, 3 to 0, 3 to 0), seen)
        assertEquals(10 - 3, roomAtStart)
        assertFalse(a.loading)
    }

    @Test
    fun `only what fits loads`() = runTest {
        val a = ChatAttachments(FakeCodec)
        val image = png(20, 20)
        a.addAll(List(9) { image })
        val pendingAtStart = mutableListOf<Int>()
        a.addListener { pendingAtStart.add(a.pending) }
        a.addAll(listOf(image, image, image))
        assertEquals(1, pendingAtStart.first())
        assertEquals(10, a.items.size)
        assertEquals("At most 10 images and files per message.", a.problem)
    }

    // The Dart widget test of the attachment strip, as far as it is the model's: each image still loading is
    // pending (a spinner each) until it joins the items (its thumbnail).
    @Test
    fun `images still loading stay pending, each joining the items once ready`() = runTest {
        val a = ChatAttachments(FakeCodec)
        val image = png(20, 20)
        val gates = List(3) { CompletableDeferred<Unit>() }
        assertFalse(a.loading)
        val done = launch { a.addFiles(gates.mapIndexed { i, gate -> Picked("shot$i.png", image, gate = gate) }) }
        runCurrent()
        assertEquals(3, a.pending)
        assertTrue(a.loading)
        for (i in 0 until 3) {
            gates[i].complete(Unit)
            runCurrent()
            assertEquals(i + 1, a.items.size)
            if (i < 2) assertEquals(2 - i, a.pending)
        }
        done.join()
        assertFalse(a.loading)
    }
}
