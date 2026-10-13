import 'package:dzep_macos/main_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_fakes.dart';

final mac = TargetPlatformVariant.only(TargetPlatform.macOS);

/// The main window on Ideas, with Alpha, Beta and Gamma (newest first: Gamma
/// on top).
Future<FakeApp> pumpMain(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(1400, 900)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = await FakeApp.create();
  for (final t in ['Alpha', 'Beta', 'Gamma']) {
    app.fakeStore.add(title: t);
  }
  await tester.pumpWidget(
    window(
      ListenableBuilder(
        listenable: app,
        builder: (_, _) => MainWindow(app: app),
      ),
    ),
  );
  await app.openMain();
  await tester.pumpAndSettle();
  return app;
}

/// The text field with [hint] as its placeholder.
EditableText fieldWithHint(WidgetTester tester, String hint) => tester.widget<EditableText>(
  find.descendant(
    of: find.ancestor(of: find.text(hint), matching: find.byType(TextField)),
    matching: find.byType(EditableText),
  ),
);

/// The title of the item the detail pane shows; null when nothing is.
String? detailTitle(WidgetTester tester) {
  final title = find.descendant(
    of: find.ancestor(of: find.text('Untitled idea'), matching: find.byType(TextField)),
    matching: find.byType(EditableText),
  );
  return title.evaluate().isEmpty ? null : tester.widget<EditableText>(title).controller.text;
}

Future<void> cmd(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('after a click on the detail outside its fields, the window keys still work', (tester) async {
    await pumpMain(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    final description = fieldWithHint(tester, 'Description: context, links, how it could work…');
    await tester.tap(
      find.ancestor(of: find.text('Description: context, links, how it could work…'), matching: find.byType(TextField)),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(description.focusNode.hasFocus, isTrue);

    // The detail's footer: nothing to focus there, and the field lets go.
    await tester.tap(find.textContaining('Added '), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(description.focusNode.hasFocus, isFalse);

    await press(tester, LogicalKeyboardKey.escape);
    await cmd(tester, LogicalKeyboardKey.keyF);
    final search = fieldWithHint(tester, 'Search').focusNode;
    expect(search.hasFocus, isTrue);

    await tester.tap(find.textContaining('Added '), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(search.hasFocus, isFalse);
    await press(tester, LogicalKeyboardKey.slash);
    expect(search.hasFocus, isTrue);
  }, variant: mac);

  testWidgets('↑/↓ move the selection through the list', (tester) async {
    await pumpMain(tester);
    expect(detailTitle(tester), isNull);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(detailTitle(tester), 'Gamma');
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(detailTitle(tester), 'Alpha');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(detailTitle(tester), 'Beta');
  }, variant: mac);

  testWidgets('⌫ deletes the selected item, with Undo', (tester) async {
    final app = await pumpMain(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);

    await press(tester, LogicalKeyboardKey.backspace);
    expect(app.fakeStore.ideas.map((i) => i.title), ['Beta', 'Alpha']);
    expect(detailTitle(tester), 'Beta');

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(app.fakeStore.ideas.map((i) => i.title), ['Gamma', 'Beta', 'Alpha']);
  }, variant: mac);

  testWidgets('⌫ and arrows in a text field stay the field’s', (tester) async {
    final app = await pumpMain(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    final search = fieldWithHint(tester, 'Search').focusNode;
    await tester.tap(find.ancestor(of: find.text('Search'), matching: find.byType(TextField)));
    await tester.pump();
    expect(search.hasFocus, isTrue);

    await press(tester, LogicalKeyboardKey.backspace);
    await press(tester, LogicalKeyboardKey.arrowDown);

    expect(app.fakeStore.ideas, hasLength(3));
    expect(detailTitle(tester), 'Gamma');
  }, variant: mac);

  testWidgets('⌘F and / focus the search; Esc clears it, then goes back to the list', (tester) async {
    await pumpMain(tester);
    final search = fieldWithHint(tester, 'Search');

    await cmd(tester, LogicalKeyboardKey.keyF);
    expect(search.focusNode.hasFocus, isTrue);
    await tester.enterText(find.byWidgetPredicate((w) => w is EditableText && w.focusNode == search.focusNode), 'bet');
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.escape);
    expect(search.controller.text, isEmpty);
    expect(search.focusNode.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.escape);
    expect(search.focusNode.hasFocus, isFalse);

    // Back on the list, the list's keys work again.
    await press(tester, LogicalKeyboardKey.slash);
    expect(search.focusNode.hasFocus, isTrue);
  }, variant: mac);

  testWidgets('⌘N focuses the new-item field', (tester) async {
    await pumpMain(tester);

    await cmd(tester, LogicalKeyboardKey.keyN);
    expect(fieldWithHint(tester, 'New idea…  ↵').focusNode.hasFocus, isTrue);
  }, variant: mac);

  testWidgets('Settings opened over a focused field takes the keys; Esc closes it', (tester) async {
    final app = await pumpMain(tester);
    await cmd(tester, LogicalKeyboardKey.keyN);
    final field = fieldWithHint(tester, 'New idea…  ↵').focusNode;

    app.setSettingsOpen(open: true);
    await tester.pumpAndSettle();
    expect(field.hasFocus, isFalse);

    await press(tester, LogicalKeyboardKey.escape);
    expect(app.settingsOpen, isFalse);
    // And the field has the focus back.
    expect(field.hasFocus, isTrue);
  }, variant: mac);
}
