import 'dart:async';

import 'package:dzep_core/chat.dart';
import 'package:dzep_core/chat_view.dart';
import 'package:dzep_core/ui.dart';
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

/// The text field typing goes to (in Ask, not the transcript's text).
Finder input() => find.descendant(of: find.byType(TextField), matching: find.byType(EditableText));

/// Puts the caret in the mode's field at [offset].
Future<void> caret(WidgetTester tester, int offset) async {
  tester.widget<EditableText>(input()).controller.selection = TextSelection.collapsed(offset: offset);
  await tester.pump();
}

/// The list row showing [label] (the last of that text: in Ask the
/// transcript above may show it too) is the one ↑/↓ have picked.
bool picked(WidgetTester tester, String label) =>
    tester.widget<Container>(find.ancestor(of: find.text(label).last, matching: find.byType(Container)).first).color ==
    C.sel;

Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await tester.pumpAndSettle();
}

Conversation chat(String id, String question, int minute) => Conversation(
  id: id,
  createdAt: DateTime.utc(2026, 10, 10, 9, minute),
  updatedAt: DateTime.utc(2026, 10, 10, 9, minute),
  messages: [
    ChatMessage(fromUser: true, text: question),
    ChatMessage(fromUser: false, text: 'answer to $question'),
  ],
);

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

  group('Note browses RECENT NOTES', () {
    Future<FakeApp> pumpNotes(WidgetTester tester) async {
      final app = await pumpPopup(tester, mode: 'note', open: false);
      app.fakeStore
        ..addNote('Older')
        ..addNote('Newer');
      await app.openPopup();
      await tester.pumpAndSettle();
      return app;
    }

    testWidgets('↓ goes in only from the last line; ↑/↓ move, ↑ past the top and Esc come back', (tester) async {
      final app = await pumpNotes(tester);
      await tester.enterText(input(), 'one\ntwo');

      // On the first line ↓ is the field's.
      await caret(tester, 1);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(find.text('back'), findsNothing);
      expect(picked(tester, 'Newer'), isFalse);

      await caret(tester, 7);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect((picked(tester, 'Newer'), picked(tester, 'Older')), (true, false));
      expect(find.text('back'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect((picked(tester, 'Newer'), picked(tester, 'Older')), (false, true));
      // The last row stays picked.
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(picked(tester, 'Older'), isTrue);

      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect((picked(tester, 'Newer'), picked(tester, 'Older')), (false, false));
      expect(find.text('browse'), findsOneWidget);

      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.escape);
      expect(picked(tester, 'Newer'), isFalse);
      expect(app.popupOpen, isTrue);
      expect(tester.widget<EditableText>(input()).focusNode.hasFocus, isTrue);
      expect(tester.widget<EditableText>(input()).controller.text, 'one\ntwo');
    }, variant: mac);

    testWidgets('a long line wrapped: ↓ from its first row stays in the field', (tester) async {
      await pumpNotes(tester);
      await tester.enterText(input(), 'word ' * 40);
      await caret(tester, 0);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(picked(tester, 'Newer'), isFalse);
    }, variant: mac);

    testWidgets('↵ opens the picked note in the main window, as a click does', (tester) async {
      final app = await pumpNotes(tester);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.enter);

      final older = app.fakeStore.notes.last;
      expect((app.pendingSelect, app.mainOpen, app.popupOpen), (older.id, true, false));
    }, variant: mac);

    testWidgets('⌘O opens the picked note in the main window, ⌘P in the note window', (tester) async {
      final app = await pumpNotes(tester);
      final newer = app.fakeStore.notes.first;
      await tester.enterText(input(), 'draft');
      await key(tester, LogicalKeyboardKey.arrowDown);
      await cmd(tester, LogicalKeyboardKey.keyO);
      await tester.pumpAndSettle();
      expect((app.pendingSelect, app.mainOpen), (newer.id, true));

      await app.openPopup();
      await tester.pumpAndSettle();
      await key(tester, LogicalKeyboardKey.arrowDown);
      await cmd(tester, LogicalKeyboardKey.keyP);
      await tester.pumpAndSettle();
      expect((app.noteOpen, app.noteId), (true, newer.id));
      // The draft stays a draft.
      expect(app.fakeStore.notes, hasLength(2));
    }, variant: mac);
  });

  group('Ask browses the recent chats', () {
    Future<(FakeApp, Conversation, Conversation)> pumpChats(WidgetTester tester) async {
      final app = await pumpPopup(tester, mode: 'ask', open: false);
      final older = chat('c1', 'Older question', 1);
      final newer = chat('c2', 'Newer question', 2);
      app.fakeChats
        ..chats.addAll([older, newer])
        ..resume(newer);
      await app.openPopup();
      await tester.pumpAndSettle();
      return (app, older, newer);
    }

    testWidgets('↓ from the last line lists them; ↵ goes on with the picked one', (tester) async {
      final (app, older, newer) = await pumpChats(tester);
      expect(find.text('RECENT CHATS'), findsNothing);
      await tester.enterText(input(), 'one\ntwo');

      await caret(tester, 1);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(find.text('RECENT CHATS'), findsNothing);

      await caret(tester, 7);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(find.text('RECENT CHATS'), findsOneWidget);
      // Newest first; the one shown is the first picked.
      expect(picked(tester, 'Newer question'), isTrue);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(picked(tester, 'Older question'), isTrue);

      await key(tester, LogicalKeyboardKey.enter);
      expect(app.fakeChats.current, older);
      expect(find.text('RECENT CHATS'), findsNothing);
      expect(find.text('answer to Older question'), findsOneWidget);
      // The question being written stays, and nothing was asked.
      expect(tester.widget<EditableText>(input()).controller.text, 'one\ntwo');
      expect(tester.widget<EditableText>(input()).focusNode.hasFocus, isTrue);
      expect(app.popupOpen, isTrue);
    }, variant: mac);

    testWidgets('Esc and ↑ past the top go back to the chat shown', (tester) async {
      final (app, _, newer) = await pumpChats(tester);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.text('RECENT CHATS'), findsNothing);
      expect((app.popupOpen, app.fakeChats.current), (true, newer));

      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(find.text('RECENT CHATS'), findsNothing);
      expect(app.fakeChats.current, newer);

      await key(tester, LogicalKeyboardKey.escape);
      expect(app.popupOpen, isFalse);
    }, variant: mac);

    testWidgets('⌘O opens the picked chat in the main window; ⌘N still starts a new one', (tester) async {
      final (app, older, _) = await pumpChats(tester);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await cmd(tester, LogicalKeyboardKey.keyO);
      await tester.pumpAndSettle();
      expect((app.pendingChat, app.pendingChats, app.mainOpen), (older, true, true));

      await app.openPopup();
      await tester.pumpAndSettle();
      await key(tester, LogicalKeyboardKey.arrowDown);
      await cmd(tester, LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(app.fakeChats.current, isNull);
      expect(find.text('RECENT CHATS'), findsNothing);
    }, variant: mac);
  });
}
