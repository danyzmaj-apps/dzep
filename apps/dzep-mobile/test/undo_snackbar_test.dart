import 'package:dzep_core/idea.dart';
import 'package:dzep_mobile/mobile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screenshots/fakes.dart';

void main() {
  // Flutter keeps a SnackBar with an action up until it's dismissed unless
  // `persist: false`: an Undo toast would stay for good.
  testWidgets('the Undo toast after deleting an idea goes away on its own', (tester) async {
    final now = DateTime.now();
    final idea = Idea(id: 'i0', title: 'Soil sensors', createdAt: now, updatedAt: now);
    final store = FakeStore()..put(idea);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DetailPage(idea: idea, store: store),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Idea deleted'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Idea deleted'), findsNothing);
  });
}
