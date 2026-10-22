import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pocketterm_core/chat_images.dart';

Future<Uint8List> png(int w, int h) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.teal);
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<Size> sizeOf(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
  frame.image.dispose();
  return size;
}

void main() {
  testWidgets('a small image is sent as it is', (tester) async {
    await tester.runAsync(() async {
      final raw = await png(maxImageSide, 300);
      final image = await prepareChatImage(raw);
      expect(image!.mime, 'image/png');
      expect(identical(image.bytes, raw), isTrue);
    });
  });

  testWidgets('a big image is scaled to fit, keeping its shape', (tester) async {
    await tester.runAsync(() async {
      final image = await prepareChatImage(await png(3000, 1000));
      expect(image!.mime, 'image/png');
      expect(await sizeOf(image.bytes), const Size(2048, 683));
    });
  });

  testWidgets('a tall image is scaled by its height', (tester) async {
    await tester.runAsync(() async {
      final image = await prepareChatImage(await png(500, 4096));
      expect(await sizeOf(image!.bytes), const Size(250, 2048));
    });
  });

  testWidgets('something that is not an image is refused', (tester) async {
    await tester.runAsync(() async {
      expect(await prepareChatImage(Uint8List.fromList('hello, not a picture'.codeUnits)), isNull);
    });
  });

  test('image types are told by their first bytes', () {
    expect(sniffImageType(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D])), 'image/png');
    expect(sniffImageType(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), 'image/jpeg');
    expect(sniffImageType(Uint8List.fromList('GIF89a'.codeUnits)), 'image/gif');
    expect(sniffImageType(Uint8List.fromList('RIFF\x00\x00\x00\x00WEBPVP8 '.codeUnits)), 'image/webp');
    expect(sniffImageType(Uint8List.fromList('RIFF\x00\x00\x00\x00WAVEfmt '.codeUnits)), isNull);
    expect(sniffImageType(Uint8List.fromList([0x49, 0x49, 0x2A, 0x00])), isNull, reason: 'TIFF gets re-encoded');
  });

  XFile picked(String name, List<int> bytes, {int? length}) =>
      XFile.fromData(Uint8List.fromList(bytes), path: '/picked/$name', length: length);

  testWidgets('a picked document goes as a file, a picked picture as an image, in the order they came', (tester) async {
    await tester.runAsync(() async {
      final a = ChatAttachments();
      await a.addFiles([
        picked('notes.pdf', '%PDF-1.7'.codeUnits),
        picked('shot.png', await png(40, 30)),
        picked('README', 'plain words'.codeUnits),
      ]);
      expect(a.problem, isNull);
      expect(a.items, [isA<ChatFile>(), isA<ChatImage>(), isA<ChatFile>()]);
      final pdf = a.items.first as ChatFile;
      expect((pdf.name, pdf.mime, String.fromCharCodes(pdf.bytes)), ('notes.pdf', 'application/pdf', '%PDF-1.7'));
      expect((a.items.last as ChatFile).mime, 'application/octet-stream');
    });
  });

  testWidgets('a file over 20 MB is left out and said so; the others still come', (tester) async {
    await tester.runAsync(() async {
      final a = ChatAttachments();
      await a.addFiles([
        picked('huge.zip', const [1, 2, 3], length: maxChatFileBytes + 1),
        picked('small.txt', 'ok'.codeUnits),
      ]);
      expect(a.items.map((i) => (i as ChatFile).name), ['small.txt']);
      expect(a.problem, '"huge.zip" is too large: files can be up to 20 MB.');

      await a.addFiles([
        picked('exactly.bin', const [0], length: maxChatFileBytes),
      ]);
      expect(a.problem, isNull, reason: 'the most that, sealed, still fits the server');
      expect(a.items, hasLength(2));
    });
  });

  testWidgets('a message takes 10 images and files together, no more', (tester) async {
    await tester.runAsync(() async {
      final a = ChatAttachments();
      final image = await png(20, 20);
      await a.addAll([for (var i = 0; i < 4; i++) image]);
      await a.addFiles([for (var i = 0; i < 8; i++) picked('doc$i.txt', 'x'.codeUnits)]);
      expect(a.items, hasLength(10));
      expect(a.items.whereType<ChatImage>(), hasLength(4));
      expect(a.room, 0);
      expect(a.problem, 'At most 10 images and files per message.');

      await a.addAll([image]);
      expect(a.items, hasLength(10));
      expect(a.problem, 'At most 10 images and files per message.');

      // Sent: what came meanwhile stays.
      a.removeSent(List.of(a.items.take(9)));
      expect(a.items.map((i) => (i as ChatFile).name), ['doc5.txt']);
    });
  });
}
