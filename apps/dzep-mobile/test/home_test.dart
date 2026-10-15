import 'dart:async';

import 'package:dzep_core/idea.dart';
import 'package:dzep_mobile/chrome.dart';
import 'package:dzep_mobile/mobile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screenshots/fakes.dart';

/// A store with a todo, an idea and a note, edited in that order.
FakeStore _store() {
  final store = FakeStore();
  final t0 = DateTime(2026, 10, 14, 9);
  for (final (i, (kind, title)) in [
    (Kind.todo, 'Renew the domain'),
    (Kind.idea, 'Watering schedule'),
    (Kind.note, 'Trip to Ljubljana'),
  ].indexed) {
    store.put(
      Idea(
        id: 'i$i',
        kind: kind,
        title: title,
        notes: kind == Kind.note ? '$title\nTrain at 7:42' : '',
        createdAt: t0.add(Duration(hours: i)),
        updatedAt: t0.add(Duration(hours: i)),
      ),
    );
  }
  return store;
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(const MethodChannel('dzep/native'), (_) async => null)
      ..setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/messages'), (_) async => null)
      ..setMockStreamHandler(
        const EventChannel('com.llfbandit.app_links/events'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      )
      // The Terminal tab would join the Mac over Supabase: it stays waiting here.
      ..setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) => Completer<Object?>().future,
      );
  });

  Future<void> open(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(786, 1704)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MobileApp(session: await FakeSession.create(_store(), FakeChats())));
    await tester.pump();
  }

  Finder tab(String label) => find.descendant(of: find.byType(AppTabBar), matching: find.text(label));

  testWidgets('three tabs, Terminal in the middle, and the app opens on it', variant: TargetPlatformVariant.mobile(), (
    tester,
  ) async {
    await open(tester);
    final labels = [
      for (final t in tester.widgetList<Text>(find.descendant(of: find.byType(AppTabBar), matching: find.byType(Text))))
        if (t.data case final d? when int.tryParse(d) == null) d,
    ];
    expect(labels, ['Pocket', 'Terminal', 'Ask']);
    expect(find.text('Reaching your Mac…'), findsOneWidget, reason: 'the Terminal tab is up');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Pocket holds todos, ideas and notes together; a pill narrows it to one kind',
    variant: TargetPlatformVariant.mobile(),
    (tester) async {
      await open(tester);
      await tester.tap(tab('Pocket'));
      await tester.pump(const Duration(milliseconds: 300));

      // All: the open todo first, then the note and the idea, most recently changed first.
      final titles = ['Renew the domain', 'Trip to Ljubljana', 'Watering schedule'];
      final ys = [for (final t in titles) tester.getTopLeft(find.textContaining(t)).dy];
      expect(ys, orderedEquals([...ys]..sort()), reason: 'rows in this order: $titles');

      await tester.tap(find.byKey(const ValueKey('show-notes')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Trip to Ljubljana'), findsOneWidget);
      expect(find.textContaining('Renew the domain'), findsNothing);
      expect(find.textContaining('Watering schedule'), findsNothing);
      expect(find.byTooltip('New note'), findsOneWidget, reason: '+ writes a note here');

      await tester.tap(find.byKey(const ValueKey('show-todos')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Renew the domain'), findsOneWidget);
      expect(find.textContaining('Trip to Ljubljana'), findsNothing);
      expect(find.byTooltip('New todo'), findsOneWidget);
    },
  );
}
