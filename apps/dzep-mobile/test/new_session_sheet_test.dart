import 'dart:io';

import 'package:dzep_core/terminal_remote.dart';
import 'package:dzep_mobile/terminal_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late Directory dir;
  late List<(String, Map<String, dynamic>)> sent;
  late TerminalRemote remote;

  /// What the sheet pops, once [pumpSheet] opened it.
  late Future<({String window, bool agent})?> popped;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dzep_new_session');
    sent = [];
    remote = TerminalRemote(
      SupabaseClient('http://localhost:1', 'anon'),
      'u1',
      dir,
      from: 'phone',
      send: (event, payload) => sent.add((event, payload)),
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// The Mac online with [roots] as its Project folders; null: a Mac that
  /// predates them.
  void macState(List<String>? roots) => remote.handle('state', {
    'windows': <Object>[],
    'sessions': <Object>[],
    'projects': <Object>[],
    'roots': ?roots,
    'home': '/Users/me',
  });

  /// The `run` the phone sent last, after the turn of the event loop it goes out on.
  Future<Map<String, dynamic>> lastRun(WidgetTester tester) async {
    await tester.pump(Duration.zero);
    return sent.lastWhere((s) => s.$1 == 'run').$2;
  }

  Future<void> openNewProject(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const ValueKey('new-project')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('project-name')), name);
    await tester.pump();
  }

  /// The sheet opened over a page.
  Future<void> pumpSheet(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => popped = showModalBottomSheet<({String window, bool agent})>(
                context: context,
                isScrollControlled: true,
                builder: (_) => NewSessionSheet(remote: remote),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('no project folders: New project… is off and the sheet says where to add one, once', (tester) async {
    macState(const []);
    await pumpSheet(tester);
    final tile = tester.widget<ListTile>(find.byKey(const ValueKey('new-project')));
    expect(tile.enabled, isFalse);
    expect(tile.subtitle, isNull);
    expect(find.byKey(const ValueKey('no-roots')), findsOneWidget);
    // The state's cache write, not waited for.
    remote.flush();
  });

  testWidgets('a Mac without Project folders: no New project…, and no hint about a setting it lacks', (tester) async {
    macState(null);
    await pumpSheet(tester);
    expect(find.byKey(const ValueKey('new-project')), findsNothing);
    expect(find.byKey(const ValueKey('no-roots')), findsNothing);
    remote.flush();
  });

  testWidgets('New project… makes the folder under the picked root, kept when the list changes', (tester) async {
    macState(const ['/Users/me/Code', '/Users/me/Work']);
    await pumpSheet(tester);
    expect(find.byKey(const ValueKey('no-roots')), findsNothing);
    await openNewProject(tester, 'demo');
    expect(find.text('New project'), findsOneWidget);
    await tester.tap(find.text('~/Work'));
    await tester.pump();
    // The Mac adds a folder in front of the picked one meanwhile.
    macState(const ['/Users/me/New', '/Users/me/Code', '/Users/me/Work']);
    await tester.pump();
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '~/Work')).selected, isTrue);

    await tester.tap(find.text('Create and open'));
    final run = await lastRun(tester);
    expect(
      run,
      allOf(
        containsPair('op', 'create'),
        containsPair('root', '/Users/me/Work'),
        containsPair('name', 'demo'),
        containsPair('agent', true),
      ),
    );
    // No going back while it's under way.
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Back')).onPressed, isNull);

    remote.handle('ran', {'id': run['id'], 'window': 'kitty-1/9'});
    await tester.pumpAndSettle();
    expect(await popped, (window: 'kitty-1/9', agent: true));
    remote.flush();
  });

  testWidgets("the Mac's refusal shows, and the form stays to try again", (tester) async {
    macState(const ['/Users/me/Code']);
    await pumpSheet(tester);
    await openNewProject(tester, 'demo');
    await tester.tap(find.text('Create and open'));
    final run = await lastRun(tester);
    remote.handle('ran', {'id': run['id'], 'error': 'There is already something named demo there.'});
    await tester.pumpAndSettle();

    expect(find.text('There is already something named demo there.'), findsOneWidget);
    expect(find.byKey(const ValueKey('project-name')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Back')).onPressed, isNotNull);
    remote.flush();
  });
}
