package com.danyzmaj.pocketterm.core

// The types of the files a prompt takes, by their extension: the phone names a file's type from
// its name, the computer gives a file without an extension the one its type has.

/** The type of a file called [name]; application/octet-stream when its extension says nothing known. */
fun fileMime(name: String): String = MIMES[fileExtension(name)] ?: "application/octet-stream"

/** The extension files of type [mime] have (`pdf`), or null. */
fun mimeExtension(mime: String): String? {
    val type = mime.split(';').first().trim().lowercase()
    return MIMES.entries.firstOrNull { it.value == type }?.key
}

/** What follows the last dot of [name], in lower case; empty when none. */
fun fileExtension(name: String): String {
    val dot = name.lastIndexOf('.')
    return if (dot <= 0) "" else name.substring(dot + 1).lowercase()
}

// The first extension of a type is the one the computer gives it.
private val MIMES: Map<String, String> = linkedMapOf(
    "pdf" to "application/pdf",
    "txt" to "text/plain",
    "log" to "text/plain",
    "md" to "text/markdown",
    "csv" to "text/csv",
    "tsv" to "text/tab-separated-values",
    "html" to "text/html",
    "xml" to "application/xml",
    "json" to "application/json",
    "yaml" to "application/yaml",
    "yml" to "application/yaml",
    "zip" to "application/zip",
    "gz" to "application/gzip",
    "rtf" to "application/rtf",
    "doc" to "application/msword",
    "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls" to "application/vnd.ms-excel",
    "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "ppt" to "application/vnd.ms-powerpoint",
    "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "pages" to "application/vnd.apple.pages",
    "numbers" to "application/vnd.apple.numbers",
    "key" to "application/vnd.apple.keynote",
    "png" to "image/png",
    "jpg" to "image/jpeg",
    "jpeg" to "image/jpeg",
    "gif" to "image/gif",
    "webp" to "image/webp",
    "heic" to "image/heic",
    "heif" to "image/heif",
    "tif" to "image/tiff",
    "tiff" to "image/tiff",
    "bmp" to "image/bmp",
    "svg" to "image/svg+xml",
    "mp3" to "audio/mpeg",
    "m4a" to "audio/mp4",
    "wav" to "audio/wav",
    "mp4" to "video/mp4",
    "mov" to "video/quicktime",
)
