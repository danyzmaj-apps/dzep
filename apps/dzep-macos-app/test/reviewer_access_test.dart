import 'dart:io';

import 'package:dzep_core/backend.dart';
import 'package:dzep_core/session.dart';
import 'package:dzep_macos/integrations.dart';
import 'package:dzep_macos/main_window.dart';
import 'package:dzep_macos/onboarding/reviewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'app_fakes.dart';

void main() {
  late FakeApp app;
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('dzep-reviewer'));
  tearDown(() => home.deleteSync(recursive: true));

  void macSize(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(1000, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Settings → Reviewer access → Codes…, with [existing] codes on the server.
  Future<void> openFromSettings(WidgetTester tester, {List<ReviewerCode> existing = const []}) async {
    macSize(tester);
    app = await FakeApp.create();
    app.reviewer.addAll(existing);
    final integrations = Integrations(home: home.path, run: (_, _) async => ProcessResult(0, 1, '', ''));
    await tester.pumpWidget(
      window(
        Stack(
          children: [SettingsSheet(app: app, integrations: integrations)],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reviewer access'), findsOneWidget);
    await tester.tap(find.text('Codes…'));
    await tester.pumpAndSettle();
  }

  testWidgets('a reviewer code is made for a separate demo account, shown with its QR and link, then revoked', (
    tester,
  ) async {
    await openFromSettings(
      tester,
      existing: [ReviewerCode(id: 'old', label: 'Play review', expiresAt: DateTime(2026, 11, 20))],
    );
    expect(find.textContaining('signs a phone into a separate demo account'), findsOneWidget);
    expect(find.textContaining('can use Ask'), findsOneWidget);
    expect(find.text('Play review'), findsOneWidget);
    expect(find.textContaining('Until 20 Nov 2026 · not used yet'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'App Store review');
    await tester.tap(find.text('90 days'));
    await tester.tap(find.text('Make a code'));
    await tester.pumpAndSettle();
    expect(app.madeCodes, [(days: 90, label: 'App Store review')]);
    final link = const Backend(
      url: 'https://example.supabase.co',
      key: 'test',
    ).linkWithCode('REVW-1AAA-BBBB-CCCC-DDDD-EEEE-FFFF');
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('$link'), findsOneWidget);
    expect(find.text('App Store review'), findsOneWidget);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, '$link');
    expect(find.text('Link copied.'), findsOneWidget);

    // Revoking the code just made takes its QR away too.
    await tester.tap(find.text('Revoke').first);
    await tester.pumpAndSettle();
    expect(app.revoked, ['code-1']);
    expect(find.text('App Store review'), findsNothing);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('Play review'), findsOneWidget);

    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(app.revoked, ['code-1', 'old']);
    expect(find.text('None.'), findsOneWidget);
  });

  testWidgets('when the server refuses, the sheet says why and keeps the codes', (tester) async {
    await openFromSettings(
      tester,
      existing: [ReviewerCode(id: 'old', label: 'Play review', expiresAt: DateTime(2026, 11, 20))],
    );
    app.reviewerFailure = 'Your server is older than this app.';
    await tester.tap(find.text('Make a code'));
    await tester.pumpAndSettle();
    expect(find.text('Your server is older than this app.'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);

    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(find.text('Play review'), findsOneWidget);
    expect(app.revoked, isEmpty);
  });

  testWidgets('Save QR as PNG writes a PNG of the link, never over an older one', (tester) async {
    macSize(tester);
    app = await FakeApp.create();
    await tester.pumpWidget(window(ReviewerAccessSheet(session: app, downloads: home)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'App Store');
    await tester.tap(find.text('Make a code'));
    await tester.pumpAndSettle();

    for (final name in ['Džep reviewer code – App Store.png', 'Džep reviewer code – App Store 2.png']) {
      await tester.tap(find.text('Save QR as PNG'));
      final file = File('${home.path}/$name');
      for (var i = 0; i < 200 && find.textContaining('Saved “$name”').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(file.existsSync(), isTrue, reason: name);
      expect(file.readAsBytesSync().sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(find.textContaining('Saved “$name”'), findsOneWidget);
    }
  });
}
