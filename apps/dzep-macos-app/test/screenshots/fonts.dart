import 'dart:io';

import 'package:flutter/services.dart';

const _system = '/System/Library/Fonts';

/// The Mac's system font (SF Pro) under every family the macOS theme asks
/// for, Menlo for code, the emoji, and the Material icons from the Flutter
/// SDK: real text in the screenshots instead of the test font's boxes.
Map<String, List<String>> get _fonts {
  // flutter_tester sits in <flutter>/bin/cache/artifacts/engine/<platform>/.
  final artifacts = File(Platform.resolvedExecutable).parent.parent.parent.path;
  final menlo = File('$_system/Menlo.ttc').existsSync() ? '$_system/Menlo.ttc' : '$_system/SFNSMono.ttf';
  return {
    '$_system/SFNS.ttf': ['.AppleSystemUIFont', 'CupertinoSystemText', 'CupertinoSystemDisplay', 'Roboto'],
    menlo: ['Menlo'],
    '$_system/Apple Symbols.ttf': ['Apple Symbols'],
    '$_system/Apple Color Emoji.ttc': ['Apple Color Emoji'],
    '$artifacts/material_fonts/MaterialIcons-Regular.otf': ['MaterialIcons'],
  };
}

/// The first font file this machine lacks; null when it has them all.
String? missingFont() => _fonts.keys.where((path) => !File(path).existsSync()).firstOrNull;

Future<void> loadRealFonts() async {
  for (final MapEntry(key: path, value: names) in _fonts.entries) {
    final bytes = ByteData.sublistView(File(path).readAsBytesSync());
    for (final name in names) {
      await (FontLoader(name)..addFont(Future.value(bytes))).load();
    }
  }
}
