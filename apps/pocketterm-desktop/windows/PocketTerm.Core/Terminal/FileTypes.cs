namespace PocketTerm.Core;

/// <summary>The types of the files a prompt takes, by their extension: the phone names a file's type
/// from its name, the computer gives a file without an extension the one its type has.</summary>
public static class FileTypes
{
    // The first extension of a type is the one the computer gives it.
    private static readonly (string Extension, string Mime)[] Mimes =
    [
        ("pdf", "application/pdf"),
        ("txt", "text/plain"),
        ("log", "text/plain"),
        ("md", "text/markdown"),
        ("csv", "text/csv"),
        ("tsv", "text/tab-separated-values"),
        ("html", "text/html"),
        ("xml", "application/xml"),
        ("json", "application/json"),
        ("yaml", "application/yaml"),
        ("yml", "application/yaml"),
        ("zip", "application/zip"),
        ("gz", "application/gzip"),
        ("rtf", "application/rtf"),
        ("doc", "application/msword"),
        ("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        ("xls", "application/vnd.ms-excel"),
        ("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        ("ppt", "application/vnd.ms-powerpoint"),
        ("pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
        ("pages", "application/vnd.apple.pages"),
        ("numbers", "application/vnd.apple.numbers"),
        ("key", "application/vnd.apple.keynote"),
        ("png", "image/png"),
        ("jpg", "image/jpeg"),
        ("jpeg", "image/jpeg"),
        ("gif", "image/gif"),
        ("webp", "image/webp"),
        ("heic", "image/heic"),
        ("heif", "image/heif"),
        ("tif", "image/tiff"),
        ("tiff", "image/tiff"),
        ("bmp", "image/bmp"),
        ("svg", "image/svg+xml"),
        ("mp3", "audio/mpeg"),
        ("m4a", "audio/mp4"),
        ("wav", "audio/wav"),
        ("mp4", "video/mp4"),
        ("mov", "video/quicktime"),
    ];

    /// <summary>The type of a file called <paramref name="name"/>; application/octet-stream when its
    /// extension says nothing known.</summary>
    public static string FileMime(string name)
    {
        var ext = FileExtension(name);
        foreach (var (e, mime) in Mimes)
        {
            if (e == ext) return mime;
        }
        return "application/octet-stream";
    }

    /// <summary>The extension files of type <paramref name="mime"/> have (<c>pdf</c>), or null.</summary>
    public static string? MimeExtension(string mime)
    {
        var type = mime.Split(';')[0].DartTrim().ToLowerInvariant();
        foreach (var (e, m) in Mimes)
        {
            if (m == type) return e;
        }
        return null;
    }

    /// <summary>What follows the last dot of <paramref name="name"/>, in lower case; empty when none.</summary>
    public static string FileExtension(string name)
    {
        var dot = name.LastIndexOf('.');
        return dot <= 0 ? "" : name[(dot + 1)..].ToLowerInvariant();
    }
}
