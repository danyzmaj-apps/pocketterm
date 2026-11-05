package com.danyzmaj.pocketterm.core

import kotlin.test.Test
import kotlin.test.assertEquals

/** tool/vectors/vectors.json `localApiPing`, `fileTypes`, `chatImages` and `desktops`. */
class MiscVectorsTest {
    private fun cases(section: String, name: String) = Vectors.section(section)[name].arr!!.map { it.obj!! }

    @Test
    fun localApiPing() {
        for (c in cases("localApiPing", "cases")) {
            val nonce = c["nonce"].str!!
            // apps/pocketterm-desktop/lib/local_api.dart LocalApi.pingProof, and its nonce rule.
            val proof = hmacSha256(c["token"].str!!.toByteArray(), "pocketterm-ping\n${c["port"].int}\n$nonce".toByteArray())
            assertEquals(c["proof"].str, Vectors.toHex(proof), c["note"].str)
            assertEquals(c["nonceAccepted"].bool, nonce.length in 16..128, c["note"].str)
        }
    }

    @Test
    fun fileTypes() {
        for (c in cases("fileTypes", "byName")) {
            val name = c["name"].str!!
            assertEquals(c["extension"].str, fileExtension(name), c["note"].str)
            assertEquals(c["mime"].str, fileMime(name), c["note"].str)
        }
        for (c in cases("fileTypes", "extensionOf")) assertEquals(c["extension"].str, mimeExtension(c["mime"].str!!), c["note"].str)
    }

    @Test
    fun chatImageLimits() {
        val l = Vectors.section("chatImages")["limits"].obj!!
        assertEquals(l["maxChatAttachments"].int, maxChatAttachments)
        assertEquals(l["maxChatFileBytes"].int, maxChatFileBytes)
        assertEquals(l["maxBlobBytes"].int, Server.maxBlobBytes)
        assertEquals(l["maxImageSide"].int, maxImageSide)
        assertEquals(l["keepAsIsMaxBytes"].int, keepAsIsMaxBytes)
        assertEquals(l["imageExtensions"].arr!!.map { it.str!! }.toSet(), imageExtensions)
    }

    @Test
    fun sniffImageType() {
        for (c in cases("chatImages", "sniffImageType")) assertEquals(c["mime"].str, sniffImageType(Vectors.hex(c["bytes"].str!!)), c["note"].str)
    }

    @Test
    fun formatBytes() {
        for (c in cases("chatImages", "formatBytes")) assertEquals(c["text"].str, formatBytes(c["bytes"].long!!), c["note"].str)
    }

    @Test
    fun desktops() {
        val s = Vectors.section("desktops")
        assertEquals(s["onlineWithinSeconds"].long, Desktop.onlineWithin.inWholeSeconds)
        assertEquals(s["keepForDays"].long, Desktops.keepFor.inWholeDays)
        for (c in cases("desktops", "cases")) {
            val d = Desktop.fromJson(c["input"].obj!!)
            assertEquals(c["output"].obj, d.toJson(), c["note"].str)
            assertEquals(c["windows"].bool, d.windows, c["note"].str)
        }
    }
}
