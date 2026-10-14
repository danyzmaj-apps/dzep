import 'dart:io';

import 'package:dzep_core/agent.dart';
import 'package:dzep_macos/integrations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_fakes.dart';

/// The files under [dir], by their path below it, hidden ones left out.
Map<String, String> filesIn(String dir) => {
  for (final f in Directory(dir).listSync(recursive: true).whereType<File>())
    if (!f.uri.pathSegments.last.startsWith('.')) f.path.substring(dir.length + 1): f.readAsStringSync(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String home;

  setUp(() => home = Directory.systemTemp.createTempSync('dzep-integrations').path);
  tearDown(() => Directory(home).deleteSync(recursive: true));

  group('omp', () {
    test('installs both extensions, and tells an outdated copy from a current one', () async {
      final integrations = Integrations(home: home);
      expect(await integrations.state(Agent.omp), (installed: false, current: false, problem: null));

      await integrations.install(Agent.omp);
      final dir = '$home/.omp/agent/extensions';
      expect(filesIn(dir), filesIn('integrations/omp'));
      expect(filesIn(dir).keys, containsAll(['idea.ts', 'live.ts']));
      expect(await integrations.state(Agent.omp), (installed: true, current: true, problem: null));

      File('$dir/live.ts').writeAsStringSync('// older');
      expect(await integrations.state(Agent.omp), (installed: true, current: false, problem: null));

      File('$dir/idea.ts').deleteSync();
      expect((await integrations.state(Agent.omp)).installed, isFalse);
    });

    test('replaces a symlinked extension instead of writing through it', () async {
      final dir = Directory('$home/.omp/agent/extensions')..createSync(recursive: true);
      final source = File('$home/checkout-live.ts')..writeAsStringSync('// my checkout');
      Link('${dir.path}/live.ts').createSync(source.path);

      await Integrations(home: home).install(Agent.omp);
      expect(source.readAsStringSync(), '// my checkout');
      expect(FileSystemEntity.isLinkSync('${dir.path}/live.ts'), isFalse);
      expect(File('${dir.path}/live.ts').readAsStringSync(), File('integrations/omp/live.ts').readAsStringSync());
    });
  });

  group('Claude Code', () {
    late FakeClaude claude;
    late Integrations integrations;
    late String dir;

    setUp(() {
      claude = FakeClaude('$home/bin/claude');
      File(claude.path).createSync(recursive: true);
      integrations = Integrations(home: home, run: claude.run, claudePaths: ['$home/nope/claude', claude.path]);
      dir = '$home/.config/dzep/claude-plugin';
    });

    Map<String, Object?> listed({required String from, bool enabled = true}) => {
      'id': 'dzep@dzep',
      'enabled': enabled,
      'readFromFolder': '$from/plugins/dzep',
    };

    test('a first install copies the marketplace without its tests, adds it and installs the plugin', () async {
      File('$dir/plugins/dzep/hooks/gone.ts').createSync(recursive: true);

      await integrations.install(Agent.claude);
      final expected = filesIn('integrations/claude')..removeWhere((f, _) => f.startsWith('plugins/dzep/tests/'));
      expect(filesIn(dir), expected);
      expect(
        File('$dir/.claude-plugin/marketplace.json').readAsStringSync(),
        File('integrations/claude/.claude-plugin/marketplace.json').readAsStringSync(),
      );
      expect(File('$dir/plugins/dzep/.claude-plugin/plugin.json').existsSync(), isTrue);
      expect(Directory('$dir/plugins/dzep/tests').existsSync(), isFalse);
      expect(claude.calls, [
        '--version',
        'plugin list --json',
        'plugin marketplace add $dir --json',
        'plugin install dzep@dzep --json',
      ]);

      claude.list = [listed(from: dir)];
      expect(await integrations.state(Agent.claude), (installed: true, current: true, problem: null));
      File('$dir/plugins/dzep/hooks/hooks.json').writeAsStringSync('{}');
      expect(await integrations.state(Agent.claude), (installed: true, current: false, problem: null));
    });

    test('updating refreshes the marketplace and the plugin, and turns a disabled one back on', () async {
      claude.list = [listed(from: dir, enabled: false)];
      expect((await integrations.state(Agent.claude)).installed, isFalse);
      claude.calls.clear();

      await integrations.install(Agent.claude);
      expect(claude.calls, [
        '--version',
        'plugin list --json',
        'plugin marketplace update dzep --json',
        'plugin update dzep@dzep --json',
        'plugin enable dzep@dzep --json',
      ]);
    });

    test('a dzep plugin loading from elsewhere is moved over to the copy', () async {
      claude.list = [listed(from: '$home/Dev/dzep/apps/dzep-macos-app/integrations/claude')];
      expect((await integrations.state(Agent.claude)).installed, isFalse);
      claude.calls.clear();

      await integrations.install(Agent.claude);
      expect(claude.calls.skip(2), ['plugin marketplace add $dir --json', 'plugin update dzep@dzep --json']);
    });

    test('a missing claude is said plainly, and nothing is run or copied', () async {
      File(claude.path).deleteSync();
      const missing = (installed: false, current: false, problem: "Claude Code isn't installed");
      expect(await integrations.state(Agent.claude), missing);
      await expectLater(
        integrations.install(Agent.claude),
        throwsA(isA<IntegrationException>().having((e) => e.message, 'message', "Claude Code isn't installed")),
      );
      expect(claude.calls, isEmpty);
      expect(Directory(dir).existsSync(), isFalse);
    });

    test("claude found only by the login shell's PATH is used", () async {
      File(claude.path).renameSync('$home/claude');
      final onPath = FakeClaude('$home/claude')..onPath = '$home/claude\n';
      final found = Integrations(home: home, run: onPath.run, claudePaths: [claude.path]);
      expect(await found.state(Agent.claude), (installed: false, current: false, problem: null));
      expect(onPath.calls, ['--version', 'plugin list --json']);
    });

    test('a Claude Code older than mods is too old', () async {
      claude.version = '2.1.286 (Claude Code)';
      expect(
        (await integrations.state(Agent.claude)).problem,
        'Claude Code 2.1.286 is too old: update it to 2.1.287 or later',
      );
      claude.version = '2.2.0 (Claude Code)';
      expect((await integrations.state(Agent.claude)).problem, isNull);
    });

    test('mods switched off are noticed through claude plugin test', () async {
      expect(await integrations.claudeModsOff(), isFalse);
      claude.modsOff = true;
      expect(await integrations.claudeModsOff(), isTrue);
      expect(claude.calls.last, startsWith('plugin test '));
      // The empty directory it tests is gone again.
      expect(Directory(claude.calls.last.substring('plugin test '.length)).existsSync(), isFalse);

      File(claude.path).deleteSync();
      expect(await integrations.claudeModsOff(), isFalse);
    });

    test('a failing claude command fails the install with what it said', () async {
      claude.fail = 'plugin install dzep@dzep --json';
      await expectLater(
        integrations.install(Agent.claude),
        throwsA(isA<IntegrationException>().having((e) => e.message, 'message', 'Plugin "dzep" not found')),
      );
    });
  });
}
