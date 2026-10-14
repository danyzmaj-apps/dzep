import 'dart:io';

import 'package:flutter/services.dart';

/// The Mac's San Francisco under every family the iOS theme asks for.
const _sansFamilies = [
  'CupertinoSystemText',
  'CupertinoSystemDisplay',
  '.AppleSystemUIFont',
  '.SF Pro Text',
  '.SF Pro Display',
  'SF Pro Text',
  'Roboto',
];

/// Replaces the test's Ahem boxes with real fonts: San Francisco, Menlo for
/// code and terminals, and the Material icons from the Flutter SDK. Null when
/// all loaded, else what's missing (not a Mac, or an SDK without its fonts).
Future<String?> loadRealFonts() async {
  const sans = '/System/Library/Fonts/SFNS.ttf';
  const menlo = '/System/Library/Fonts/Menlo.ttc';
  const sfMono = '/System/Library/Fonts/SFNSMono.ttf';
  final icons = _materialIcons();
  if (!File(sans).existsSync()) return sans;
  if (icons == null) return 'MaterialIcons-Regular.otf in the Flutter SDK';
  final mono = File(menlo).existsSync() ? menlo : sfMono;
  if (!File(mono).existsSync()) return mono;

  Future<void> load(String family, String path) async {
    final bytes = File(path).readAsBytesSync();
    await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }

  for (final family in _sansFamilies) {
    await load(family, sans);
  }
  await load('Menlo', mono);
  await load('MaterialIcons', icons);
  return null;
}

/// `<sdk>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf`, found
/// from FLUTTER_ROOT or by walking up from flutter_tester (in the SDK's cache).
String? _materialIcons() {
  const rel = 'bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && File('$root/$rel').existsSync()) return '$root/$rel';
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.parent.path != dir.path) {
    if (File('${dir.path}/$rel').existsSync()) return '${dir.path}/$rel';
    dir = dir.parent;
  }
  return null;
}
