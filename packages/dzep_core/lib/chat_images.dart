import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:dzep_core/chat.dart';
import 'package:dzep_core/ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';

/// How many images one question takes (the `ask` function's limit too).
const maxChatImages = 4;

/// The longest side an image is sent at: plenty for reading a screenshot,
/// and it keeps uploads and the model's image tokens small.
const maxImageSide = 2048;

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

const _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'heif', 'tif', 'tiff', 'bmp'};

/// What's on the clipboard as images: copied image files (Finder) or image
/// data (a screenshot, an image copied in a browser). Empty if neither.
Future<List<Uint8List>> clipboardImages() async {
  if (Platform.isMacOS) {
    // Files first: for a copied file, the image reader returns its icon.
    final files = await Pasteboard.files();
    if (files.isNotEmpty) {
      return [
        for (final path in files)
          if (_imageExtensions.contains(path.split('.').last.toLowerCase())) await File(path).readAsBytes(),
      ];
    }
  }
  final image = await Pasteboard.image;
  return image == null ? const [] : [image];
}

/// Images picked by the user: the photo picker on the phone, a file dialog on the Mac.
Future<List<Uint8List>> pickImages({required int limit}) async {
  if (limit <= 0) return const [];
  final picked = limit == 1
      ? [?await ImagePicker().pickImage(source: ImageSource.gallery)]
      : await ImagePicker().pickMultiImage(limit: limit);
  return [for (final f in picked) await f.readAsBytes()];
}

/// The images a composer holds until the question is sent; each loads
/// through [prepareChatImage]. Errors (not an image, too many) go to
/// [problem] for the composer to show.
class ChatAttachments extends ChangeNotifier {
  final List<ChatImage> images = [];
  String? problem;

  bool get isEmpty => images.isEmpty;
  int get room => maxChatImages - images.length;

  Future<void> addAll(List<Uint8List> raws) async {
    problem = null;
    var skipped = 0;
    for (final raw in raws) {
      if (room <= 0) {
        problem = 'At most $maxChatImages images per question.';
        break;
      }
      final image = await prepareChatImage(raw);
      if (image == null) {
        skipped++;
      } else {
        images.add(image);
      }
    }
    if (skipped > 0) problem ??= skipped == 1 ? "That isn't an image Džep can read." : "$skipped files aren't images.";
    notifyListeners();
  }

  /// Pastes images from the clipboard; false if it holds none (a text paste
  /// then goes ahead as usual).
  Future<bool> paste() async {
    final raws = await clipboardImages();
    if (raws.isEmpty) return false;
    await addAll(raws);
    return true;
  }

  Future<void> pick() async => await addAll(await pickImages(limit: room));

  void removeAt(int i) {
    images.removeAt(i);
    problem = null;
    notifyListeners();
  }

  /// Hands the images over for sending and empties the composer.
  List<ChatImage> take() {
    final taken = List.of(images);
    images.clear();
    problem = null;
    notifyListeners();
    return taken;
  }
}

/// ⌘V on the Mac (a hardware keyboard on the phone pastes through the
/// field's own menu, so the phone has a Paste button instead).
bool isPasteKey(KeyEvent e) =>
    e is KeyDownEvent &&
    e.logicalKey == LogicalKeyboardKey.keyV &&
    HardwareKeyboard.instance.isMetaPressed &&
    !HardwareKeyboard.instance.isShiftPressed;

/// 📎: pick images to attach (a file dialog on the Mac, the photo picker on the phone).
class AttachButton extends StatelessWidget {
  const AttachButton({required this.attachments, this.size = 18, this.around, super.key});
  final ChatAttachments attachments;
  final double size;

  /// Wraps the pick, e.g. so the popup stays open while the dialog shows.
  final Future<void> Function(Future<void> Function() pick)? around;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: Platform.isMacOS ? 'Attach images (or paste one with ⌘V)' : 'Attach images',
    child: Semantics(
      button: true,
      label: 'Attach images',
      child: Hoverable(
        onTap: () => unawaited(around == null ? attachments.pick() : around!(attachments.pick)),
        builder: (hover) => Padding(
          padding: const EdgeInsets.only(left: 10, top: 2),
          child: Icon(Icons.attach_file, size: size, color: hover ? C.text : C.dim),
        ),
      ),
    ),
  );
}

/// The composer's pending images, each with a ✕; nothing when empty.
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
      final images = attachments.images;
      final problem = attachments.problem;
      return AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: images.isEmpty && problem == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: EdgeInsets.only(top: top, bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (images.isNotEmpty)
                      // 2 plus each thumbnail's 6pt corner room: 8 between them.
                      Wrap(
                        spacing: 2,
                        runSpacing: 2,
                        children: [
                          for (final (i, image) in images.indexed)
                            _Removable(
                              key: ObjectKey(image),
                              onRemove: () => attachments.removeAt(i),
                              child: _Thumb(bytes: image.bytes, size: size),
                            ),
                        ],
                      ),
                    if (problem != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(problem, style: const TextStyle(fontSize: 12, color: Color(0xFFFCA5A5))),
                      ),
                  ],
                ),
              ),
      );
    },
  );
}

/// A thumbnail with its ✕ dot on the corner. The dot is 20pt but a 40pt
/// square catches the tap, and the corner room keeps both inside the Stack,
/// which only hit-tests within its own size.
class _Removable extends StatelessWidget {
  const _Removable({required this.onRemove, required this.child, super.key});
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
          label: 'Remove image',
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
                    border: Border.all(color: C.line2),
                  ),
                  child: const Icon(Icons.close, size: 12, color: C.text),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// A question's images in the transcript; a tap shows one full size.
class MessageImages extends StatelessWidget {
  const MessageImages({required this.chat, required this.paths, this.size = 96, super.key});
  final ChatStore chat;
  final List<String> paths;
  final double size;

  @override
  Widget build(BuildContext context) => SelectionContainer.disabled(
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final path in paths)
          FutureBuilder<Uint8List>(
            future: chat.image(path),
            builder: (context, snap) {
              final bytes = snap.data;
              if (bytes == null) return _Placeholder(size: size, failed: snap.hasError);
              return GestureDetector(
                onTap: () => unawaited(_showFull(context, bytes)),
                child: MouseRegion(
                  cursor: SystemMouseCursors.zoomIn,
                  child: _Thumb(bytes: bytes, size: size),
                ),
              );
            },
          ),
      ],
    ),
  );

  Future<void> _showFull(BuildContext context, Uint8List bytes) => showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (dialog) => GestureDetector(
      onTap: () => Navigator.of(dialog).pop(),
      child: InteractiveViewer(
        maxScale: 6,
        child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
      ),
    ),
  );
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.bytes, required this.size});
  final Uint8List bytes;
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: C.field,
        border: Border.all(color: C.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Image.memory(bytes, fit: BoxFit.cover, cacheWidth: (size * 3).round(), gaplessPlayback: true),
    ),
  );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.size, required this.failed});
  final double size;
  final bool failed;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: C.field,
      border: Border.all(color: C.line),
      borderRadius: BorderRadius.circular(8),
    ),
    alignment: Alignment.center,
    child: failed
        ? const Icon(Icons.broken_image_outlined, size: 20, color: C.dim2)
        : const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
  );
}
