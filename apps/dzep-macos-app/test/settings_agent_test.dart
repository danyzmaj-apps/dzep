import 'dart:io';

import 'package:dzep_core/agent.dart';
import 'package:dzep_macos/integrations.dart';
import 'package:dzep_macos/main_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_fakes.dart';

void main() {
  late String home;
  late FakeApp app;

  setUp(() => home = Directory.systemTemp.createTempSync('dzep-settings').path);
  tearDown(() => Directory(home).deleteSync(recursive: true));

  /// Settings over nothing, its integrations in [home], with no `claude` on
  /// this "Mac" unless [claude] is one.
  Future<void> pumpSettings(WidgetTester tester, {FakeClaude? claude}) async {
    tester.view
      ..physicalSize = const Size(1000, 1200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    app = await FakeApp.create();
    final integrations = Integrations(
      home: home,
      run: claude?.run ?? (_, _) async => ProcessResult(0, 1, '', ''),
      claudePaths: [?claude?.path],
    );
    await tester.pumpWidget(
      window(
        ListenableBuilder(
          listenable: app,
          builder: (_, _) => Stack(
            children: [SettingsSheet(app: app, integrations: integrations)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Gives real file work (copies, temporary directories) real time, until
  /// [text] shows.
  Future<void> settle(WidgetTester tester, String text) async {
    for (var i = 0; i < 200 && find.textContaining(text).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  testWidgets('omp is the default, and its extensions install from Settings', (tester) async {
    await pumpSettings(tester);
    expect(app.codingAgent, Agent.omp);
    expect(find.text('Džep in omp'), findsOneWidget);
    expect(find.textContaining('Not installed'), findsOneWidget);

    await tester.tap(find.text('Install'));
    await settle(tester, 'restart');
    expect(find.text('Installed · restart your omp sessions to load it'), findsOneWidget);
    expect(File('$home/.omp/agent/extensions/live.ts').existsSync(), isTrue);
  });

  testWidgets('choosing Claude Code keeps it, and says plainly when it isn’t installed', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('Claude Code'));
    await tester.pumpAndSettle();

    expect(app.codingAgent, Agent.claude);
    expect(find.text('Džep in Claude Code'), findsOneWidget);
    expect(find.text("Claude Code isn't installed"), findsOneWidget);
    expect(find.text('Install'), findsNothing);
  });

  testWidgets('Claude Code with mods off says how to turn them on, also right after installing', (tester) async {
    final claude = FakeClaude('$home/bin/claude')
      ..list = [
        {'id': 'dzep@dzep', 'enabled': true, 'readFromFolder': '$home/.config/dzep/claude-plugin/plugins/dzep'},
      ]
      ..modsOff = true;
    File(claude.path).createSync(recursive: true);
    await pumpSettings(tester, claude: claude);
    await tester.tap(find.text('Claude Code'));
    await settle(tester, 'mods');
    const hint = 'run claude /login, start claude once, then restart your Claude sessions';
    expect(find.text('Claude Code has mods turned off for now: $hint'), findsOneWidget);

    // Installed, not the bundled copy yet: updating can't turn mods on.
    await tester.tap(find.text('Update'));
    await settle(tester, 'Installed ·');
    expect(find.text('Installed · Claude Code has mods turned off for now: $hint'), findsOneWidget);

    claude.modsOff = false;
    await tester.tap(find.text('omp'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude Code'));
    await settle(tester, 'Installed and up to date');
    expect(find.text('Installed and up to date'), findsOneWidget);
  });
}
