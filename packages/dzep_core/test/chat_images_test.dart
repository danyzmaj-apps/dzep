import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dzep_core/chat_images.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
