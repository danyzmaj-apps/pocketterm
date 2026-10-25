import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/file_types.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/ui.dart';

/// How many images and files one message to a session takes.
const maxChatAttachments = 10;

/// The largest file a message takes: sealed, it's the most the server holds
/// (20 MB).
const int maxChatFileBytes = Server.maxBlobBytes - sealedOverhead;

/// The longest side an image is sent at: plenty for reading a screenshot,
/// and it keeps uploads and the model's image tokens small.
const maxImageSide = 2048;

/// Something a message takes along: a [ChatImage] or a [ChatFile].
sealed class ChatAttachment {
  const ChatAttachment();
}

/// An image about to be sent: its bytes and their type.
class ChatImage extends ChatAttachment {
  const ChatImage(this.bytes, this.mime);
  final Uint8List bytes;

  /// image/png, image/jpeg, image/gif or image/webp.
  final String mime;
}

/// A file about to be sent as it is (a document, an archive): the agent
/// gets it under [name], as a file on the computer.
class ChatFile extends ChatAttachment {
  const ChatFile(this.name, this.bytes, this.mime);
  final String name;
  final Uint8List bytes;
  final String mime;
}

/// Picked files with these extensions go as images, scaled down like photos.
const _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'heif', 'tif', 'tiff', 'bmp'};

/// [bytes] for people: `512 bytes`, `3.4 KB`, `12.0 MB`.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes bytes';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// [raw] as an image to send: kept as it is when it's a PNG, JPEG, GIF or
/// WebP no bigger than [maxImageSide] and 4 MB, else decoded, scaled down to
/// fit and re-encoded as PNG (which also turns TIFF, HEIC and the like into
/// something every model reads). Null when it isn't an image.
Future<ChatImage?> prepareChatImage(Uint8List raw) async {
  final ui.ImmutableBuffer buffer;
  final ui.ImageDescriptor descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(raw);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
  } on Object {
    return null;
  }
  try {
    final w = descriptor.width;
    final h = descriptor.height;
    final mime = sniffImageType(raw);
    if (mime != null && max(w, h) <= maxImageSide && raw.length <= 4 << 20) return ChatImage(raw, mime);
    final scale = min(1, maxImageSide / max(w, h));
    final codec = await descriptor.instantiateCodec(
      targetWidth: max(1, (w * scale).round()),
      targetHeight: max(1, (h * scale).round()),
    );
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return png == null ? null : ChatImage(png.buffer.asUint8List(), 'image/png');
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
}

/// The type a model accepts, from the file's first bytes; null for others.
String? sniffImageType(Uint8List b) {
  bool at(int i, List<int> sig) {
    if (b.length < i + sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (b[i + k] != sig[k]) return false;
    }
    return true;
  }

  if (at(0, [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (at(0, [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (at(0, [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) return 'image/webp';
  return null;
}

/// What's on the clipboard as an image (a screenshot, an image copied in a
/// browser). Empty if none.
Future<List<Uint8List>> _clipboardImages() async {
  final image = await Pasteboard.image;
  return image == null ? const [] : [image];
}

/// Images picked from the photo picker. `imageQuality` makes image_picker
/// re-encode each as JPEG, so a HEIC photo never reaches the computer.
Future<List<Uint8List>> _pickImages({required int limit}) async {
  if (limit <= 0) return const [];
  final picked = limit == 1
      ? [?await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90)]
      : await ImagePicker().pickMultiImage(limit: limit, imageQuality: 90);
  return [for (final f in picked) await f.readAsBytes()];
}

/// The images and files a composer holds until the message is sent, at most
/// [maxChatAttachments], in the order they came. Images load through
/// [prepareChatImage]; files go as they are, up to [maxChatFileBytes] each.
/// Errors (not an image, too many, too large) go to [problem] for the
/// composer to show.
class ChatAttachments extends ChangeNotifier {
  final List<ChatAttachment> items = [];
  String? problem;

  bool get isEmpty => items.isEmpty;
  int get room => maxChatAttachments - items.length;

  static const _tooMany = 'At most $maxChatAttachments images and files per message.';

  Future<void> addAll(List<Uint8List> raws) async {
    problem = null;
    var skipped = 0;
    for (final raw in raws) {
      if (room <= 0) {
        problem = _tooMany;
        break;
      }
      final image = await prepareChatImage(raw);
      if (image == null) {
        skipped++;
      } else {
        items.add(image);
      }
    }
    if (skipped > 0) {
      problem ??= skipped == 1 ? "That isn't an image PocketTerm can read." : "$skipped files aren't images.";
    }
    notifyListeners();
  }

  /// Adds files picked from the phone's files. Images among them (by their
  /// extension or their first bytes) go as images; a file over
  /// [maxChatFileBytes] is left out, and said so.
  Future<void> addFiles(List<XFile> files) async {
    problem = null;
    final tooLarge = <String>[];
    for (final f in files) {
      if (room <= 0) {
        problem = _tooMany;
        break;
      }
      final name = f.name.isNotEmpty ? f.name : 'file';
      final named = _imageExtensions.contains(fileExtension(name));
      if (!named && await f.length() > maxChatFileBytes) {
        tooLarge.add(name);
        continue;
      }
      final bytes = await f.readAsBytes();
      final image = named || sniffImageType(bytes) != null ? await prepareChatImage(bytes) : null;
      if (image != null) {
        items.add(image);
      } else if (bytes.length > maxChatFileBytes) {
        tooLarge.add(name);
      } else {
        final mime = f.mimeType;
        items.add(ChatFile(name, bytes, mime == null || mime.isEmpty ? fileMime(name) : mime));
      }
    }
    if (tooLarge.isNotEmpty) {
      const most = 'files can be up to ${maxChatFileBytes ~/ (1000 * 1000)} MB';
      problem ??= tooLarge.length == 1
          ? '"${tooLarge.single}" is too large: $most.'
          : '${tooLarge.length} files are too large: $most.';
    }
    notifyListeners();
  }

  /// Pastes images from the clipboard; false if it holds none (a text paste
  /// then goes ahead as usual).
  Future<bool> paste() async {
    final raws = await _clipboardImages();
    if (raws.isEmpty) return false;
    await addAll(raws);
    return true;
  }

  Future<void> pick() async => await addAll(await _pickImages(limit: room));

  void removeAt(int i) {
    items.removeAt(i);
    problem = null;
    notifyListeners();
  }

  /// Takes out [sent] (the ones a message took), keeping what came since.
  void removeSent(Iterable<ChatAttachment> sent) {
    final gone = Set<ChatAttachment>.identity()..addAll(sent);
    items.removeWhere(gone.contains);
    notifyListeners();
  }
}

/// The composer's pending images and files, each with a ✕: a thumbnail per
/// image, a chip with its name and size per file; nothing when empty.
/// It grows and shrinks smoothly, and [top] spaces it from what sits above
/// only while it shows something.
class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip({required this.attachments, this.size = 56, this.top = 0, super.key});
  final ChatAttachments attachments;
  final double size;
  final double top;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: attachments,
    builder: (context, _) {
      final items = attachments.items;
      final problem = attachments.problem;
      return AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: items.isEmpty && problem == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: EdgeInsets.only(top: top, bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (items.isNotEmpty)
                      // 2 plus each thumbnail's 6pt corner room: 8 between them.
                      Wrap(
                        spacing: 2,
                        runSpacing: 2,
                        children: [
                          for (final (i, item) in items.indexed)
                            _Removable(
                              key: ObjectKey(item),
                              label: switch (item) {
                                ChatImage() => 'Remove image',
                                ChatFile(:final name) => 'Remove $name',
                              },
                              onRemove: () => attachments.removeAt(i),
                              child: switch (item) {
                                ChatImage(:final bytes) => _Thumb(bytes: bytes, size: size),
                                final ChatFile file => _FileChip(file: file, height: size),
                              },
                            ),
                        ],
                      ),
                    if (problem != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(problem, style: TextStyle(fontSize: 12, color: C.error)),
                      ),
                  ],
                ),
              ),
      );
    },
  );
}

/// Images and files as they went with a message: [AttachmentStrip]'s thumbnails and chips, without their ✕.
class AttachmentThumbs extends StatelessWidget {
  const AttachmentThumbs(this.items, {this.size = 56, this.alignment = WrapAlignment.start, super.key});
  final List<ChatAttachment> items;
  final double size;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    alignment: alignment,
    children: [
      for (final item in items)
        switch (item) {
          ChatImage(:final bytes) => _Thumb(bytes: bytes, size: size),
          final ChatFile file => _FileChip(file: file, height: size),
        },
    ],
  );
}

/// A thumbnail or chip with its ✕ dot on the corner. The dot is 20pt but a
/// 40pt square catches the tap, and the corner room keeps both inside the
/// Stack, which only hit-tests within its own size.
class _Removable extends StatelessWidget {
  const _Removable({required this.label, required this.onRemove, required this.child, super.key});
  final String label;
  final VoidCallback onRemove;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Padding(padding: const EdgeInsets.only(top: 6, right: 6), child: child),
      Positioned(
        top: 0,
        right: 0,
        child: Semantics(
          button: true,
          label: label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onRemove,
            child: SizedBox.square(
              dimension: 40,
              child: Align(
                alignment: Alignment.topRight,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: C.bar,
                    shape: BoxShape.circle,
                    border: Border.all(color: C.line2, width: C.border),
                  ),
                  child: Icon(Icons.close, size: 12, color: C.text),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.bytes, required this.size});
  final Uint8List bytes;
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: C.round(8),
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: C.field,
        border: Border.all(color: C.line, width: C.border),
        borderRadius: C.round(8),
      ),
      child: Image.memory(bytes, fit: BoxFit.cover, cacheWidth: (size * 3).round(), gaplessPlayback: true),
    ),
  );
}

/// A file as the composer holds it: an icon, its name and its size.
class _FileChip extends StatelessWidget {
  const _FileChip({required this.file, required this.height});
  final ChatFile file;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    constraints: const BoxConstraints(maxWidth: 200),
    padding: const EdgeInsets.only(left: 10, right: 14),
    decoration: BoxDecoration(
      color: C.field,
      border: Border.all(color: C.line, width: C.border),
      borderRadius: C.round(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.insert_drive_file_outlined, size: 20, color: C.dim),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: C.text),
              ),
              const SizedBox(height: 2),
              Text(formatBytes(file.bytes.length), style: TextStyle(fontSize: 11, color: C.dim)),
            ],
          ),
        ),
      ],
    ),
  );
}
