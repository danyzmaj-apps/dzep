import 'dart:async';

import 'package:dzep_core/idea.dart';
import 'package:dzep_core/tabs.dart';
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

  /// The home page, with the tab setting saved as [order] and [hidden].
  Future<FakeSession> open(WidgetTester tester, {List<String>? order, List<String>? hidden}) async {
    tester.view
      ..physicalSize = const Size(786, 1704)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final session = await FakeSession.create(_store(), FakeChats());
    if (order != null || hidden != null) {
      await session.setTabs(TabChoice.parse(HomeTab.values, order: order, hidden: hidden));
    }
    await tester.pumpWidget(MobileApp(session: session));
    await tester.pump();
    return session;
  }

  Finder tab(String label) => find.descendant(of: find.byType(AppTabBar), matching: find.text(label));

  /// The bar's labels, left to right (badge counts left out).
  List<String> barLabels(WidgetTester tester) => [
    for (final t in tester.widgetList<Text>(find.descendant(of: find.byType(AppTabBar), matching: find.byType(Text))))
      if (t.data case final d? when int.tryParse(d) == null) d,
  ];

  testWidgets('three tabs, Terminal in the middle, and the app opens on it', variant: TargetPlatformVariant.mobile(), (
    tester,
  ) async {
    await open(tester);
    expect(barLabels(tester), ['Pocket', 'Terminal', 'Ask']);
    expect(find.text('Reaching your Mac…'), findsOneWidget, reason: 'the Terminal tab is up');
    expect(tester.takeException(), isNull);
  });

  /// Account (the avatar) → Tabs, up and settled.
  Future<void> openTabsSheet(WidgetTester tester) async {
    for (final target in [find.byTooltip('Account'), find.byKey(const ValueKey('tabs'))]) {
      await tester.tap(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  testWidgets(
    'Account → Tabs: switching Ask off takes it off the bar at once',
    variant: TargetPlatformVariant.mobile(),
    (tester) async {
      final session = await open(tester);
      await openTabsSheet(tester);
      await tester.tap(find.byKey(const ValueKey('tab-ask')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(barLabels(tester), ['Pocket', 'Terminal']);
      expect(session.tabs.hidden, {HomeTab.ask}, reason: 'kept for the next launch');

      await tester.tap(find.byKey(const ValueKey('tab-terminal')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AppTabBar), findsNothing, reason: 'one tab left: no bar');
      expect(find.text('Reaching your Mac…'), findsNothing, reason: 'Terminal was on screen; Pocket took over');

      await tester.tap(find.byKey(const ValueKey('tab-pocket')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(session.tabs.visible, [HomeTab.pocket], reason: 'the last tab showing stays');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('only Pocket showing: no bar, Pocket and its + on screen', variant: TargetPlatformVariant.mobile(), (
    tester,
  ) async {
    await open(tester, hidden: ['terminal', 'ask']);
    expect(find.byType(AppTabBar), findsNothing);
    expect(find.text('Pocket'), findsOneWidget, reason: 'the title');
    expect(find.textContaining('Renew the domain'), findsOneWidget);
    expect(find.byTooltip('New'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the bar follows the saved order; Terminal switched off, the app opens on the first tab',
    variant: TargetPlatformVariant.mobile(),
    (tester) async {
      await open(tester, order: ['ask', 'terminal', 'pocket'], hidden: ['terminal']);
      expect(barLabels(tester), ['Ask', 'Pocket']);
      expect(find.byTooltip('New chat'), findsOneWidget, reason: 'Ask is up');
      expect(find.text('Reaching your Mac…'), findsNothing);

      await tester.tap(tab('Pocket'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byTooltip('New'), findsOneWidget, reason: 'the bar picks by position, not the enum');
    },
  );

  testWidgets('dragging a row in Tabs reorders the bar', variant: TargetPlatformVariant.mobile(), (tester) async {
    await open(tester);
    await openTabsSheet(tester);
    final handle = find.descendant(of: find.byKey(const ValueKey('tab-ask')), matching: find.byIcon(Icons.drag_handle));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    final rowHeight = tester.getSize(find.byKey(const ValueKey('tab-ask'))).height;
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, -rowHeight * 0.25));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    // The row settles into place, then the order changes.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(barLabels(tester), ['Ask', 'Pocket', 'Terminal']);
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
