import 'dart:io';

import 'package:dzep_core/terminal_remote.dart';
import 'package:dzep_mobile/mobile.dart';
import 'package:dzep_mobile/session_view.dart';
import 'package:dzep_mobile/terminal_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Phone extends MobileSession {
  _Phone(SharedPreferences prefs) : super(prefs, 'iPhone');
}

const _a = '/Users/me/a';
const _b = '/Users/me/b';
const _z = '/Users/me/z';

void main() {
  late Directory dir;
  late List<(String, Map<String, dynamic>)> sent;
  late TerminalRemote remote;
  late SharedPreferences prefs;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('dzep_terminal_list');
    sent = [];
    remote = TerminalRemote(
      SupabaseClient('http://localhost:1', 'anon'),
      'u1',
      dir,
      from: 'phone',
      send: (event, payload) => sent.add((event, payload)),
    );
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// Project z: one session needing you, listed last, and a newer idle one;
  /// a: one idle; b: one working; c: one in a terminal Džep doesn't drive
  /// (IntelliJ's: no window). Plus a shell. Neither the list's order nor the
  /// folders' alphabetical one is the urgent one (z, b, a, c).
  void macState() {
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> window(String key, String cwd, String program) => {
      'key': key,
      'title': program,
      'cwd': cwd,
      'program': program,
      'app': 'kitty',
    };
    remote.handle('state', {
      'windows': [
        window('kitty-1/1', _z, 'omp'),
        window('kitty-1/2', _a, 'omp'),
        window('kitty-1/3', _b, 'omp'),
        window('kitty-1/4', '/Users/me', 'zsh'),
        window('kitty-1/5', _z, 'omp'),
      ],
      'sessions': [
        {
          'key': 'kitty-1/2',
          'id': 's2',
          'agent': 'omp',
          'window': 'kitty-1/2',
          'title': 'Idle one',
          'cwd': _a,
          'at': now - 600000,
        },
        {
          'key': 'kitty-1/3',
          'id': 's3',
          'agent': 'omp',
          'window': 'kitty-1/3',
          'title': 'Working one',
          'cwd': _b,
          'busy': true,
          'at': now,
        },
        {'key': 'pid:9', 'id': 's9', 'agent': 'omp', 'title': 'In IntelliJ', 'cwd': '/Users/me/c', 'at': now - 900000},
        {'key': 'pid:8', 'id': 's8', 'agent': 'omp', 'title': '', 'cwd': '', 'at': now - 1000000},
        {
          'key': 'kitty-1/5',
          'id': 's5',
          'agent': 'omp',
          'window': 'kitty-1/5',
          'title': 'Newer idle',
          'cwd': _z,
          'at': now - 60000,
        },
        {
          'key': 'kitty-1/1',
          'id': 's1',
          'agent': 'omp',
          'window': 'kitty-1/1',
          'title': 'Asking one',
          'cwd': _z,
          'ask': {'kind': 'approval', 'id': 'q1', 'tool': 'Bash', 'summary': 'ls'},
          'at': now - 1200000,
        },
      ],
      'projects': [_a, _b],
      'home': '/Users/me',
      'agent': 'omp',
      'opensIn': 'kitty',
    });
  }

  Future<void> pumpList(WidgetTester tester, {Key? key}) async {
    // An iPhone's screen, so the whole list is laid out.
    tester.view
      ..physicalSize = const Size(1179, 2556)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dzep/native'),
      (_) async => null,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalList(
            key: key,
            remote: remote,
            folded: _Phone(prefs).collapsedProjects,
            onFolded: _Phone(prefs).setCollapsedProjects,
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> runs(String op) => [
    for (final (event, p) in sent)
      if (event == 'run' && p['op'] == op) p,
  ];

  Finder session(String key) => find.byKey(ValueKey('session-$key'));

  /// A project heading, as read: its name and count.
  String heading(WidgetTester tester, String cwd) {
    final rows = find.descendant(of: find.byKey(ValueKey('project-$cwd')), matching: find.byType(Text));
    return tester.widgetList<Text>(rows).take(2).map((t) => t.data).join();
  }

  Finder plus(String cwd) => find.byKey(ValueKey('new-in-$cwd'));

  testWidgets('sessions are grouped by project, the one needing you first, each heading with its name and count', (
    tester,
  ) async {
    macState();
    await pumpList(tester);

    double top(String cwd) => tester.getTopLeft(find.byKey(ValueKey('project-$cwd'))).dy;
    expect(top(_z), lessThan(top(_b)), reason: 'z holds the session needing you');
    expect(top(_b), lessThan(top(_a)), reason: 'then the working one');
    expect(top(_a), lessThan(top('/Users/me/c')), reason: 'then the most recent');
    expect(heading(tester, _z), 'Z · 2');
    expect(heading(tester, _b), 'B · 1');
    expect(find.textContaining('~/'), findsNothing, reason: 'the heading names the project once, without its path');
    // A session from somewhere unknown: no + to start one there, and its
    // agent for a title.
    expect(heading(tester, ''), 'SOMEWHERE · 1');
    expect(find.byKey(const ValueKey('project-new-')), findsNothing);
    expect(find.descendant(of: session('pid:8'), matching: find.text('omp')), findsOneWidget);
    // In z's group: the asking one above the newer idle one.
    expect(tester.getTopLeft(session('kitty-1/1')).dy, lessThan(tester.getTopLeft(session('kitty-1/5')).dy));
    expect(find.text('OTHER WINDOWS'), findsOneWidget);
    expect(find.byKey(const ValueKey('term-kitty-1/4')), findsOneWidget);
    expect(
      find.ancestor(of: session('pid:9'), matching: find.byType(Dismissible)),
      findsNothing,
      reason: 'a session without a window has nothing to close',
    );
    remote.flush();
  });

  testWidgets('a long folder name gives way: its + stays on the row and tappable', (tester) async {
    const long = '/Users/me/IdeaProjects/customer-integration-service-frontend-and-more';
    remote.handle('state', {
      'windows': [
        {'key': 'kitty-1/7', 'title': 'omp', 'cwd': long, 'program': 'omp', 'app': 'kitty'},
      ],
      'sessions': [
        {'key': 'kitty-1/7', 'id': 's7', 'agent': 'omp', 'window': 'kitty-1/7', 'title': 'Long', 'cwd': long},
      ],
      'home': '/Users/me',
      'agent': 'omp',
    });
    await pumpList(tester);

    expect(tester.takeException(), isNull, reason: 'no overflow');
    expect(find.text(' · 1'), findsOneWidget);
    expect(
      tester.getSize(find.text(long.split('/').last.toUpperCase())).width,
      greaterThan(200),
      reason: 'the name gets most of the row',
    );
    await tester.tap(find.byKey(const ValueKey('new-in-$long')));
    await tester.pump(Duration.zero);
    final launch = runs('launch').single;
    expect(launch, containsPair('cwd', long));
    remote.handle('ran', {'id': launch['id'], 'error': 'No such folder.'});
    await tester.pump();
    remote.flush();
  });

  testWidgets("a project's + starts the agent there and opens its session, without folding the project", (
    tester,
  ) async {
    macState();
    await pumpList(tester);

    await tester.tap(find.byKey(const ValueKey('new-in-$_b')));
    await tester.pump(Duration.zero);
    final launch = runs('launch').single;
    expect(launch, containsPair('cwd', _b));
    expect(launch, containsPair('agent', true));
    expect(session('kitty-1/3'), findsOneWidget);
    // Tapping where the + was, now its spinner, doesn't fold the project.
    await tester.tap(find.byKey(const ValueKey('project-new-$_b')));
    await tester.pump();
    expect(session('kitty-1/3'), findsOneWidget);

    remote.handle('ran', {'id': launch['id'], 'window': 'kitty-1/9'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SessionPage), findsOneWidget);
    expect(tester.widget<SessionPage>(find.byType(SessionPage)).sessionKey, 'kitty-1/9');
    remote.flush();
  });

  testWidgets('a folded project shows only its heading, and stays folded next time', (tester) async {
    macState();
    await pumpList(tester);

    await tester.tap(find.text('A'));
    await tester.pump();
    expect(session('kitty-1/2'), findsNothing);
    expect(session('kitty-1/3'), findsOneWidget);
    expect(prefs.getStringList('dzep_terminal_folded'), [_a]);

    await pumpList(tester, key: const ValueKey('again'));
    expect(session('kitty-1/2'), findsNothing);
    expect(heading(tester, _a), 'A · 1');

    await tester.tap(find.text('A'));
    await tester.pump();
    expect(session('kitty-1/2'), findsOneWidget);
    expect(prefs.getStringList('dzep_terminal_folded'), isEmpty);

    // Folded, a session needing you still shows on its heading.
    expect(find.byKey(const ValueKey('project-needs-you-$_z')), findsNothing);
    await tester.tap(find.text('Z'));
    await tester.pump();
    expect(find.byKey(const ValueKey('project-needs-you-$_z')), findsOneWidget);
    await tester.tap(find.text('B'));
    await tester.pump();
    expect(find.byKey(const ValueKey('project-needs-you-$_b')), findsNothing, reason: "b's is only working");
    remote.flush();
  });

  testWidgets('swiping a row asks in its place, not in a dialog; Cancel or waiting leaves the window open', (
    tester,
  ) async {
    macState();
    await pumpList(tester);
    // Not to settle: a close going spins, and settling would outwait its
    // answer and the question's 5 s.
    Future<void> swipe(String key) async {
      await tester.drag(session(key), const Offset(-600, 0));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Finder sent(String window) => find.descendant(
      of: find.byKey(ValueKey('confirm-close-$window')),
      matching: find.byKey(const ValueKey('close-sent')),
    );

    await swipe('kitty-1/3');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Close this window on the Mac?'), findsOneWidget);
    expect(find.text('The omp session in ~/b ends with it.'), findsOneWidget);
    expect(session('kitty-1/3'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('close-cancel')));
    await tester.pump();
    expect(session('kitty-1/3'), findsOneWidget);

    await swipe('kitty-1/3');
    await tester.pump(const Duration(seconds: 6));
    expect(session('kitty-1/3'), findsOneWidget, reason: 'the question goes on its own');
    expect(runs('close'), isEmpty);

    await swipe('kitty-1/3');
    await tester.tap(find.byKey(const ValueKey('close-confirm')));
    await tester.pump(Duration.zero);
    final closeB = runs('close').single;
    expect(closeB, containsPair('window', 'kitty-1/3'));
    // Until the Mac answers, it shows the close going, with nothing to ask
    // or send again; another row's close doesn't change that.
    expect(sent('kitty-1/3'), findsOneWidget);
    expect(find.byKey(const ValueKey('close-confirm')), findsNothing);
    await swipe('kitty-1/2');
    await tester.tap(find.byKey(const ValueKey('close-confirm')));
    await tester.pump(Duration.zero);
    final closeA = runs('close').last;
    expect(closeA, containsPair('window', 'kitty-1/2'));
    expect(sent('kitty-1/3'), findsOneWidget);

    remote.handle('ran', {'id': closeA['id']});
    await tester.pump();
    expect(session('kitty-1/2'), findsOneWidget);
    expect(sent('kitty-1/3'), findsOneWidget, reason: "a's answer isn't b's");
    remote.handle('ran', {'id': closeB['id']});
    await tester.pump();
    expect(session('kitty-1/3'), findsOneWidget);
    expect(runs('close'), hasLength(2));
    remote.flush();
  });

  testWidgets("with the Mac out of reach, neither a + nor a row's question can be used", (tester) async {
    macState();
    await pumpList(tester);
    await tester.drag(session('kitty-1/3'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('close-confirm')), findsOneWidget);
    expect(tester.widget<IconButton>(plus(_b)).onPressed, isNotNull);

    // Nothing heard from the Mac any more, and the list looks again (the
    // app's link check does, every few seconds).
    remote
      ..attach()
      ..detach();
    await pumpList(tester);
    expect(remote.online, isFalse);
    expect(find.byKey(const ValueKey('close-confirm')), findsNothing);
    expect(session('kitty-1/3'), findsOneWidget);
    expect(tester.widget<IconButton>(plus(_b)).onPressed, isNull);
    remote.flush();
  });

  testWidgets("the session page's close button asks above the composer, then closes and goes back", (tester) async {
    macState();
    await pumpList(tester);
    await tester.tap(session('kitty-1/3'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byKey(const ValueKey('close-window')));
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Close this window on the Mac?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('close-confirm')));
    await tester.pump(Duration.zero);
    final close = runs('close').single;
    expect(close, containsPair('window', 'kitty-1/3'));
    // Until the Mac answers: the close shows going, and can't go again.
    expect(find.byKey(const ValueKey('close-sent')), findsOneWidget);
    expect(find.byKey(const ValueKey('close-confirm')), findsNothing);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('close-window'))).onPressed, isNull);
    remote.handle('ran', {'id': close['id']});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SessionPage), findsNothing);
    remote.flush();
  });

  testWidgets("a window's screen asks the same before closing, then goes back", (tester) async {
    macState();
    await pumpList(tester);
    await tester.tap(find.byKey(const ValueKey('term-kitty-1/4')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TerminalPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('close-window')));
    await tester.pump();
    expect(find.text('zsh in ~ ends with it.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('close-cancel')));
    await tester.pump();
    expect(find.text('zsh in ~ ends with it.'), findsNothing);
    expect(runs('close'), isEmpty);

    await tester.tap(find.byKey(const ValueKey('close-window')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('close-confirm')));
    await tester.pump(Duration.zero);
    final close = runs('close').single;
    expect(close, containsPair('window', 'kitty-1/4'));
    remote.handle('ran', {'id': close['id']});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TerminalPage), findsNothing);
    remote.flush();
  });

  testWidgets("a slash command for a session in a terminal Džep can't type into isn't sent as chat", (tester) async {
    macState();
    await pumpList(tester);
    await tester.tap(session('pid:9'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byKey(const ValueKey('session-input')), '/new');
    await tester.pump();
    expect(find.byKey(const ValueKey('commands-need-window')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('session-send')));
    await tester.pump();

    expect(runs('prompt'), isEmpty);
    expect(find.textContaining('Run them on the Mac.'), findsWidgets);
    expect(find.text('/new'), findsOneWidget, reason: 'what was typed stays');
    remote.flush();
  });
}
