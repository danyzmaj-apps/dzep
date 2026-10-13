import 'package:dzep_macos/controller.dart';
import 'package:dzep_macos/main_window.dart';
import 'package:dzep_macos/popup.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_fakes.dart';

final mac = TargetPlatformVariant.only(TargetPlatform.macOS);

/// Both windows as main.dart hosts them, each its own view of one app: the
/// main window in the test's view (taps work there), the popup in a second.
Future<FakeApp> pumpWindows(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(1400, 900)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = await FakeApp.create();
  await tester.pumpWidget(
    wrapWithView: false,
    ViewCollection(
      views: [
        View(
          view: tester.view,
          child: window(
            ListenableBuilder(
              listenable: app,
              builder: (_, _) => MainWindow(app: app),
            ),
          ),
        ),
        View(
          view: SecondView(tester.view),
          child: window(
            ListenableBuilder(
              listenable: app,
              builder: (_, _) => Offstage(
                offstage: !app.popupOpen,
                child: Popup(app: app),
              ),
            ),
          ),
        ),
      ],
    ),
  );
  await tester.pumpAndSettle();
  return app;
}

/// Whether the focus is in a text field of the popup, shown or hidden.
bool popupFieldFocused(WidgetTester tester) => tester
    .widgetList<EditableText>(
      find.descendant(
        of: find.byType(Popup, skipOffstage: false),
        matching: find.byType(EditableText, skipOffstage: false),
        skipOffstage: false,
      ),
    )
    .any((e) => e.focusNode.hasFocus);

void main() {
  testWidgets('the note being edited has the focus again once the popup is gone', (tester) async {
    final app = await pumpWindows(tester);
    final note = app.fakeStore.addNote('Groceries\nmilk');
    await app.openMain(select: note.id);
    await tester.pumpAndSettle();
    final editor = find.descendant(of: find.byType(NoteEditor), matching: find.byType(EditableText));
    await tester.tap(editor);
    await tester.pump();
    final focus = tester.widget<EditableText>(editor).focusNode;
    expect(focus.hasFocus, isTrue);

    for (final close in [app.closePopup, () => tester.sendKeyEvent(LogicalKeyboardKey.escape)]) {
      await app.openPopup();
      await tester.pumpAndSettle();
      expect(popupFieldFocused(tester), isTrue);
      expect(focus.hasFocus, isFalse);

      await close();
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      expect(popupFieldFocused(tester), isFalse);
    }
  }, variant: mac);

  testWidgets('what had the focus is gone: the list takes it, so its keys work', (tester) async {
    final app = await pumpWindows(tester);
    for (final t in ['Alpha', 'Beta']) {
      app.fakeStore.add(title: t);
    }
    await app.openMain();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    // The description of Beta, which is deleted while the popup is open.
    final description = find.descendant(
      of: find.ancestor(
        of: find.text('Description: context, links, how it could work…'),
        matching: find.byType(TextField),
      ),
      matching: find.byType(EditableText),
    );
    await tester.tap(description);
    await tester.pump();
    expect(tester.widget<EditableText>(description).focusNode.hasFocus, isTrue);

    await app.openPopup();
    await tester.pumpAndSettle();
    app.fakeStore.delete(app.fakeStore.ideas.first);
    await app.closePopup();
    await tester.pumpAndSettle();

    expect(popupFieldFocused(tester), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(app.fakeStore.ideas, isEmpty);
  }, variant: mac);

  testWidgets('a hidden popup keeps no focus, so typing in the main window never lands in it', (tester) async {
    final app = await pumpWindows(tester);
    await app.openPopup();
    await tester.pumpAndSettle();
    expect(popupFieldFocused(tester), isTrue);

    await app.closePopup();
    await tester.pumpAndSettle();

    expect(popupFieldFocused(tester), isFalse);
  }, variant: mac);

  testWidgets('a note window opened from the main window hides it until it closes, then shows that note', (
    tester,
  ) async {
    final app = await pumpWindows(tester);
    final note = app.fakeStore.addNote('Reps\n12');
    app.fakeStore.addNote('Newer');
    await app.openMain();
    await tester.pumpAndSettle();

    await app.openNoteWindow(id: note.id, fromMain: true);
    await tester.pumpAndSettle();
    expect((app.mainOpen, app.noteOpen), (false, true));

    await app.closeNoteWindow();
    await tester.pumpAndSettle();
    expect((app.mainOpen, app.noteOpen), (true, false));
    expect(tester.widget<NoteEditor>(find.byType(NoteEditor)).note, note);
  }, variant: mac);

  testWidgets('a note window opened from the popup closes without bringing the app up', (tester) async {
    final app = await pumpWindows(tester);
    await app.openPopup();
    await tester.pumpAndSettle();

    await app.openNoteWindow();
    await tester.pumpAndSettle();
    expect((app.popupOpen, app.noteOpen), (false, true));

    await app.closeNoteWindow();
    await tester.pumpAndSettle();
    expect(app.mainOpen, isFalse);
    expect(app.calls, isNot(contains('showMain')));
  }, variant: mac);

  testWidgets('⌘O in the popup opens the app on that mode’s list', (tester) async {
    final app = await pumpWindows(tester);
    app.fakeStore.addNote('A note');
    for (final (mode, list) in [(PopupMode.todo, '0 open'), (PopupMode.note, '1 note'), (PopupMode.idea, '0 ideas')]) {
      app.setPopupMode(mode);
      await app.openPopup();
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect((app.popupOpen, app.mainOpen), (false, true));
      expect(find.textContaining(list, findRichText: true), findsOneWidget, reason: mode.name);
    }
  }, variant: mac);
}
