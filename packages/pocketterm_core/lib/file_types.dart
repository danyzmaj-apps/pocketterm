/// The types of the files a prompt takes, by their extension: the phone
/// names a file's type from its name, the computer gives a file without an
/// extension the one its type has.
library;

/// The type of a file called [name]; application/octet-stream when its
/// extension says nothing known.
String fileMime(String name) => _mimes[fileExtension(name)] ?? 'application/octet-stream';

/// The extension files of type [mime] have (`pdf`), or null.
String? mimeExtension(String mime) {
  final type = mime.split(';').first.trim().toLowerCase();
  for (final MapEntry(:key, :value) in _mimes.entries) {
    if (value == type) return key;
  }
  return null;
}

/// What follows the last dot of [name], in lower case; empty when none.
String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

// The first extension of a type is the one the computer gives it.
const _mimes = {
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'log': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'tsv': 'text/tab-separated-values',
  'html': 'text/html',
  'xml': 'application/xml',
  'json': 'application/json',
  'yaml': 'application/yaml',
  'yml': 'application/yaml',
  'zip': 'application/zip',
  'gz': 'application/gzip',
  'rtf': 'application/rtf',
  'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'pages': 'application/vnd.apple.pages',
  'numbers': 'application/vnd.apple.numbers',
  'key': 'application/vnd.apple.keynote',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'bmp': 'image/bmp',
  'svg': 'image/svg+xml',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'wav': 'audio/wav',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
};
