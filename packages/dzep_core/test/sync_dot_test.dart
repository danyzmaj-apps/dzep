import 'package:dzep_core/store.dart';
import 'package:dzep_core/ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (platform, device) in [
    (TargetPlatform.macOS, 'Mac'),
    (TargetPlatform.iOS, 'phone'),
    (TargetPlatform.android, 'phone'),
  ]) {
    testWidgets('offline says the edits are saved on this $device (${platform.name})', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.pumpWidget(const MaterialApp(home: SyncDot(SyncState.offline)));
      expect(find.text('Offline · saved on this $device'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
