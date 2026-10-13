import 'package:dzep_core/session.dart';
import 'package:dzep_mobile/setup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpSetup(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SetupPage(session: Session('iPhone'))),
      ),
    );
  }

  testWidgets('the phone offers the Mac’s code or a pasted link, never a server setup of its own', (tester) async {
    await pumpSetup(tester);
    expect(find.text('Scan the code from your Mac'), findsOneWidget);
    expect(find.text('Paste a setup link instead'), findsOneWidget);
    expect(find.textContaining('Set up the server on this iPhone'), findsNothing);

    await tester.tap(find.text('Paste a setup link instead'));
    await tester.pump();
    expect(find.text('Connect your server'), findsOneWidget);

    await tester.tap(find.text('← Scan the code instead'));
    await tester.pump();
    expect(find.text('Scan the code from your Mac'), findsOneWidget);
  });

  testWidgets('a pasted secret key is refused before anything connects', (tester) async {
    await pumpSetup(tester);
    await tester.tap(find.text('Paste a setup link instead'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'https://abcdefgh.supabase.co');
    await tester.enterText(find.byType(TextField).last, 'sb_secret_123');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.textContaining('That is a secret key'), findsOneWidget);
    expect(find.text('Connect your server'), findsOneWidget);
  });
}
