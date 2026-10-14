import 'dart:async';

import 'package:dzep_core/chat.dart';
import 'package:dzep_core/chat_view.dart';
import 'package:dzep_macos/popup.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_fakes.dart';

final mac = TargetPlatformVariant.only(TargetPlatform.macOS);

/// The popup as main.dart hosts it: mounted while hidden, shown while open.
Future<FakeApp> pumpPopup(WidgetTester tester, {String? mode, bool open = true}) async {
  tester.view
    ..physicalSize = const Size(720, 660)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = await FakeApp.create(popupMode: mode);
  await tester.pumpWidget(
    window(
      ListenableBuilder(
        listenable: app,
        // Every glyph of the test font is a full em wide: smaller, the hint
        // bar fits as it does on a Mac.
        builder: (context, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(.8)),
          child: Offstage(
            offstage: !app.popupOpen,
            child: Popup(app: app),
          ),
        ),
      ),
    ),
  );
  if (open) {
    await app.openPopup();
    await tester.pumpAndSettle();
  }
  return app;
}

/// The mode's first field (the title in idea and todo).
EditableText field(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText).first);

Future<void> cmd(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
}

Future<void> unfocus(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  expect(field(tester).focusNode.hasFocus, isFalse);
}

void main() {
  testWidgets('⌘1 on an unfocused draft focuses it with the caret, never selecting it all', (tester) async {
    await pumpPopup(tester);
    await tester.enterText(find.byType(EditableText).first, 'hello');
    await unfocus(tester);

    await cmd(tester, LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();

    expect(field(tester).focusNode.hasFocus, isTrue);
    expect(field(tester).controller.selection, const TextSelection.collapsed(offset: 5));
  }, variant: mac);

  testWidgets('typing while no field has focus goes in at the caret', (tester) async {
    await pumpPopup(tester);
    await tester.enterText(find.byType(EditableText).first, 'helo');
    field(tester).controller.selection = const TextSelection.collapsed(offset: 3);
    await unfocus(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pumpAndSettle();

    expect(field(tester).controller.text, 'hello');
    expect(field(tester).controller.selection, const TextSelection.collapsed(offset: 4));
    expect(field(tester).focusNode.hasFocus, isTrue);
  }, variant: mac);

  testWidgets('characters typed before the Ask field is on screen land in it', (tester) async {
    final app = await pumpPopup(tester, open: false);
    app.askNext = true;
    unawaited(app.openPopup());
    // No frame yet: the Ask pane isn't built, let alone focused.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pumpAndSettle();

    expect(find.text('Ask a quick question…'), findsOneWidget);
    expect(field(tester).controller.text, 'hi');
    expect(field(tester).focusNode.hasFocus, isTrue);
  }, variant: mac);

  testWidgets('with no AI connected, Ask has no field; ↵ opens the app on the connect sheet', (tester) async {
    final app = await pumpPopup(tester, mode: 'ask');
    app.fakeChats.ai = const AiStatus(connected: false);
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsNothing);
    expect(find.byType(NoAiNotice), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect((app.popupOpen, app.mainOpen, app.pendingConnectAi), (false, true, true));

    // Connected: the field is back, focused, without what was typed meanwhile.
    app.fakeChats.ai = const AiStatus(connected: true);
    await app.openPopup();
    await tester.pumpAndSettle();
    expect(find.byType(NoAiNotice), findsNothing);
    expect(field(tester).controller.text, isEmpty);
    expect(field(tester).focusNode.hasFocus, isTrue);
  }, variant: mac);

  testWidgets('a click on the panel outside the field keeps it focused, so Esc still hides', (tester) async {
    final app = await pumpPopup(tester);
    expect(field(tester).focusNode.hasFocus, isTrue);

    await tester.tap(find.text('RECENT IDEAS'), kind: PointerDeviceKind.mouse);
    await tester.tap(find.text('hide'), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(field(tester).focusNode.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(app.popupOpen, isFalse);
  }, variant: mac);

  testWidgets('Esc hides even with no field focused', (tester) async {
    final app = await pumpPopup(tester, mode: 'note');
    await unfocus(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(app.popupOpen, isFalse);
    expect(app.calls.last, 'hidePopup');
  }, variant: mac);

  testWidgets('⌘↵ saves a note even with no field focused', (tester) async {
    final app = await pumpPopup(tester, mode: 'note');
    await tester.enterText(find.byType(EditableText).first, 'Groceries\nmilk');
    await unfocus(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);

    expect(app.fakeStore.notes.single.title, 'Groceries');
    expect(app.popupOpen, isFalse);
  }, variant: mac);

  testWidgets('⌘W hides it', (tester) async {
    final app = await pumpPopup(tester);

    await cmd(tester, LogicalKeyboardKey.keyW);

    expect(app.popupOpen, isFalse);
    expect(app.calls.last, 'hidePopup');
  }, variant: mac);

  testWidgets('⌘P takes the note being written into the note window', (tester) async {
    final app = await pumpPopup(tester, mode: 'note');
    await tester.enterText(find.byType(EditableText).first, 'Reps\n12');
    await cmd(tester, LogicalKeyboardKey.keyP);
    await tester.pumpAndSettle();

    final note = app.fakeStore.notes.single;
    expect(note.notes, 'Reps\n12');
    expect((app.noteOpen, app.noteId, app.popupOpen), (true, note.id, false));
    // The draft went with it.
    await app.openPopup();
    await tester.pumpAndSettle();
    expect(field(tester).controller.text, isEmpty);
  }, variant: mac);
}
