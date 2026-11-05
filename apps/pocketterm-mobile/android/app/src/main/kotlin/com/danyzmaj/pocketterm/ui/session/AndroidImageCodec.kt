package com.danyzmaj.pocketterm.ui.session

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.os.Build
import com.danyzmaj.pocketterm.core.ImageCodec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/**
 * The core's [ImageCodec] on Android: ImageDecoder where there is one (Android 9+: HEIF, rotation from
 * EXIF, animated images' first frame), else BitmapFactory. Off the main thread.
 */
object AndroidImageCodec : ImageCodec {
    /** Thrown from the header callback to stop ImageDecoder once it knows the size. */
    private class Measured(val width: Int, val height: Int) : RuntimeException(null, null, false, false)

    override suspend fun size(raw: ByteArray): Pair<Int, Int>? = withContext(Dispatchers.Default) {
        if (Build.VERSION.SDK_INT >= 28) {
            try {
                ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(raw))) { _, info, _ ->
                    throw Measured(info.size.width, info.size.height)
                }
                null
            } catch (m: Measured) {
                m.width to m.height
            } catch (_: Exception) {
                bounds(raw)
            }
        } else {
            bounds(raw)
        }
    }

    private fun bounds(raw: ByteArray): Pair<Int, Int>? {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(raw, 0, raw.size, o)
        return if (o.outWidth > 0 && o.outHeight > 0) o.outWidth to o.outHeight else null
    }

    override suspend fun toPng(raw: ByteArray, width: Int, height: Int): ByteArray? = withContext(Dispatchers.Default) {
        try {
            val bitmap = decode(raw, width, height) ?: return@withContext null
            val scaled = if (bitmap.width == width && bitmap.height == height) bitmap else Bitmap.createScaledBitmap(bitmap, width, height, true)
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
            if (scaled !== bitmap) scaled.recycle()
            bitmap.recycle()
            out.toByteArray()
        } catch (_: Exception) {
            null
        } catch (_: OutOfMemoryError) {
            null
        }
    }

    private fun decode(raw: ByteArray, width: Int, height: Int): Bitmap? {
        if (Build.VERSION.SDK_INT >= 28) {
            try {
                return ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(raw))) { decoder, _, _ ->
                    decoder.setTargetSize(width, height)
                    // A software bitmap: PNG encoding reads its pixels.
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                }
            } catch (_: Exception) {
                // Not one ImageDecoder reads: BitmapFactory may.
            }
        }
        val (w, h) = bounds(raw) ?: return null
        // The largest power-of-two step down that stays at or above the size wanted, then scaled exactly.
        var sample = 1
        while (w / (sample * 2) >= width && h / (sample * 2) >= height) sample *= 2
        return BitmapFactory.decodeByteArray(raw, 0, raw.size, BitmapFactory.Options().apply { inSampleSize = sample })
    }
}
