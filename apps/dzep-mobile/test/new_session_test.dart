import 'package:dzep_core/agent.dart';
import 'package:dzep_core/kitty.dart';
import 'package:dzep_core/terminal_remote.dart';
import 'package:dzep_mobile/terminal_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Mac with home /Users/me and two projects; records what it was asked to
/// start.
class FakeRemote extends ChangeNotifier implements TerminalRemote {
  final launched = <String>[];

  @override
  String home = '/Users/me';

  @override
  List<String> get projects => const ['/Users/me/Dev/app', '/Users/me/Dev/site'];

  @override
  List<TermWindow> get windows => const [];

  @override
  bool get online => true;

  @override
  TerminalLink get link => TerminalLink.online;

  @override
  Agent get agent => Agent.omp;

  @override
  DateTime? stateAt = DateTime.now();

  @override
  String? get error => null;

  @override
  Future<String> launch(String cwd, {required bool startAgent}) async {
    launched.add(cwd);
    return 'kitty-1/1';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<FakeRemote> open(WidgetTester t) async {
    final remote = FakeRemote();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NewSessionSheet(remote: remote)),
      ),
    );
    return remote;
  }

  final field = find.byKey(const ValueKey('session-folder'));
  final typedRow = find.byKey(const ValueKey('typed-folder'));

  testWidgets('a folder typed without ~ starts from the home folder, on Enter', (t) async {
    final remote = await open(t);
    await t.enterText(field, 'dev/bebi-zmaj/');
    await t.pump();
    expect(find.descendant(of: typedRow, matching: find.textContaining('~/dev/bebi-zmaj')), findsOneWidget);
    await t.testTextInput.receiveAction(TextInputAction.go);
    await t.pump();
    expect(remote.launched, ['/Users/me/dev/bebi-zmaj']);
  });

  for (final (typed, cwd) in [('~', '/Users/me'), ('~/Dev/new/', '/Users/me/Dev/new'), ('/opt/work', '/opt/work')]) {
    testWidgets('"$typed" starts in $cwd from its row', (t) async {
      final remote = await open(t);
      await t.enterText(field, typed);
      await t.pump();
      await t.tap(typedRow);
      await t.pump();
      expect(remote.launched, [cwd]);
    });
  }

  testWidgets('plain words only search the projects; Enter starts the one found', (t) async {
    final remote = await open(t);
    await t.enterText(field, 'site');
    await t.pump();
    expect(typedRow, findsNothing);
    await t.testTextInput.receiveAction(TextInputAction.go);
    await t.pump();
    expect(remote.launched, ['/Users/me/Dev/site']);
  });
}
