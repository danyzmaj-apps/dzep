import 'dart:convert';
import 'dart:io';

import 'package:dzep_core/agent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Runs [executable] with [arguments], as [Process.run] does.
typedef Run = Future<ProcessResult> Function(String executable, List<String> arguments);

/// Where an agent's Džep integration stands: installed, and current (the
/// same as the copy bundled with the app), or the problem that keeps it from
/// being installed at all.
typedef IntegrationState = ({bool installed, bool current, String? problem});

/// Installing an integration failed: [message] says why, for Settings.
class IntegrationException implements Exception {
  IntegrationException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Installs the coding agents' Džep integrations (integrations/) from the
/// copies bundled with the app: omp's extensions, Claude Code's plugin.
class Integrations {
  Integrations({String? home, AssetBundle? bundle, Run? run, this._claudePaths})
    : home = home ?? Platform.environment['HOME'] ?? '',
      _bundle = bundle ?? rootBundle,
      _run = run ?? Process.run;

  final String home;
  final AssetBundle _bundle;
  final Run _run;

  /// Where `claude` may be, before asking a login shell; the usual install
  /// places if null.
  final List<String>? _claudePaths;

  /// What Settings calls the agent: Claude's product name in full.
  static String name(Agent agent) => switch (agent) {
    Agent.omp => 'omp',
    Agent.claude => 'Claude Code',
  };

  /// The oldest Claude Code whose plugins may have mods (hooks/*.ts).
  static const minClaude = [2, 1, 287];

  /// Where omp loads extensions from.
  String get ompDir => '$home/.omp/agent/extensions';

  /// The marketplace Claude Code is pointed at: a stable copy of the bundled
  /// one, which it loads the plugin from in place.
  String get claudeDir => '$home/.config/dzep/claude-plugin';

  static const _plugin = 'dzep@dzep';

  Future<IntegrationState> state(Agent agent) async {
    switch (agent) {
      case Agent.omp:
        final files = await _bundled('integrations/omp/');
        final installed = files.keys.every((f) => File('$ompDir/$f').existsSync());
        return (installed: installed, current: installed && await _same(files, ompDir), problem: null);
      case Agent.claude:
        final claude = await _claude();
        if (claude.problem != null) return (installed: false, current: false, problem: claude.problem);
        final entry = await _listed(claude.path!);
        final installed = _loadsOurs(entry) && entry!['enabled'] != false;
        return (
          installed: installed,
          current: installed && await _same(await _bundled('integrations/claude/'), claudeDir, exact: true),
          problem: null,
        );
    }
  }

  /// Installs [agent]'s integration, or updates it to the bundled copy. Its
  /// running sessions load it when they restart.
  Future<void> install(Agent agent) async {
    switch (agent) {
      case Agent.omp:
        await Directory(ompDir).create(recursive: true);
        await _write(await _bundled('integrations/omp/'), ompDir);
      case Agent.claude:
        final claude = await _claude();
        if (claude.problem != null) throw IntegrationException(claude.problem!);
        final exe = claude.path!;
        final entry = await _listed(exe);
        final dir = Directory(claudeDir);
        if (dir.existsSync()) await dir.delete(recursive: true);
        await _write(await _bundled('integrations/claude/'), claudeDir);
        await _claudeRun(
          exe,
          _loadsOurs(entry)
              ? ['plugin', 'marketplace', 'update', 'dzep', '--json']
              : ['plugin', 'marketplace', 'add', claudeDir, '--json'],
        );
        if (entry == null) {
          await _claudeRun(exe, ['plugin', 'install', _plugin, '--json']);
        } else {
          await _claudeRun(exe, ['plugin', 'update', _plugin, '--json']);
          if (entry['enabled'] == false) await _claudeRun(exe, ['plugin', 'enable', _plugin, '--json']);
        }
    }
  }

  /// Claude Code has mods (hooks/*.ts, the plugin's whole runtime) turned
  /// off. Its rollout switch is cached as off until Claude Code, logged in,
  /// refreshes it; `claude plugin test` checks that switch before anything
  /// else and says so. False when claude can't be run at all ([state] says
  /// why).
  Future<bool> claudeModsOff() async {
    final claude = await _claude();
    if (claude.problem != null) return false;
    // An empty directory: with mods on there is nothing to run or write.
    final empty = await Directory.systemTemp.createTemp('dzep-mods');
    try {
      final r = await _run(claude.path!, ['plugin', 'test', empty.path]);
      return r.exitCode != 0 && '${r.stderr}${r.stdout}'.contains('modules are turned off');
    } finally {
      await empty.delete(recursive: true);
    }
  }

  /// The bundled files under [prefix], by their path below it.
  Future<Map<String, Uint8List>> _bundled(String prefix) async {
    final manifest = await AssetManifest.loadFromAssetBundle(_bundle);
    return {
      for (final a in manifest.listAssets().where((a) => a.startsWith(prefix)))
        a.substring(prefix.length): (await _bundle.load(a)).buffer.asUint8List(),
    };
  }

  /// [files] are in [dir] as they are here ([exact]: and nothing else is).
  static Future<bool> _same(Map<String, Uint8List> files, String dir, {bool exact = false}) async {
    for (final MapEntry(key: f, value: bytes) in files.entries) {
      final file = File('$dir/$f');
      if (!file.existsSync() || !listEquals(await file.readAsBytes(), bytes)) return false;
    }
    if (!exact) return true;
    final there = Directory(dir).listSync(recursive: true).whereType<File>().length;
    return there == files.length;
  }

  /// Writes [files] into [dir] through a rename, so a symlinked one is
  /// replaced rather than written through and nothing reads half a file.
  static Future<void> _write(Map<String, Uint8List> files, String dir) async {
    for (final MapEntry(key: f, value: bytes) in files.entries) {
      final file = File('$dir/$f');
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.dzep-tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    }
  }

  /// The `claude` executable and whether it's new enough. A GUI app has no
  /// login shell's PATH: the usual install places first, then the shell.
  Future<({String? path, String? problem})> _claude() async {
    final candidates =
        _claudePaths ??
        ['$home/.local/bin/claude', '$home/.claude/local/claude', '/opt/homebrew/bin/claude', '/usr/local/bin/claude'];
    var path = candidates.where((p) => File(p).existsSync()).firstOrNull;
    if (path == null) {
      final r = await _run('/bin/zsh', ['-lc', 'command -v claude']);
      final found = '${r.stdout}'.trim();
      if (r.exitCode == 0 && found.isNotEmpty) path = found;
    }
    if (path == null) return (path: null, problem: "Claude Code isn't installed");
    final r = await _run(path, ['--version']);
    final version = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch('${r.stdout}');
    if (version == null) return (path: path, problem: "Couldn't run Claude Code: ${_message(r)}");
    final [major, minor, patch] = [for (var i = 1; i <= 3; i++) int.parse(version[i]!)];
    final [minMajor, minMinor, minPatch] = minClaude;
    final tooOld = major != minMajor ? major < minMajor : (minor != minMinor ? minor < minMinor : patch < minPatch);
    if (tooOld) {
      return (
        path: path,
        problem: 'Claude Code ${version[0]} is too old: update it to ${minClaude.join('.')} or later',
      );
    }
    return (path: path, problem: null);
  }

  /// Claude Code's record of Džep's plugin, if it has one.
  Future<Map<String, Object?>?> _listed(String claude) async {
    final r = await _claudeRun(claude, ['plugin', 'list', '--json']);
    final list = jsonDecode('${r.stdout}') as List<Object?>;
    return list.whereType<Map<String, Object?>>().where((p) => p['id'] == _plugin).firstOrNull;
  }

  /// [entry] loads from [claudeDir] (not from a marketplace elsewhere that is
  /// also called dzep, such as a checkout of this repo).
  bool _loadsOurs(Map<String, Object?>? entry) => entry?['readFromFolder'] == '$claudeDir/plugins/dzep';

  Future<ProcessResult> _claudeRun(String claude, List<String> args) async {
    final r = await _run(claude, args);
    if (r.exitCode != 0) throw IntegrationException(_message(r));
    return r;
  }

  /// What a failed run said: the `message` of its `--json` line, else stderr.
  static String _message(ProcessResult r) {
    final last = '${r.stdout}'.trim().split('\n').last;
    try {
      if (jsonDecode(last) case {'message': final String m}) return m;
    } on FormatException {
      // Not a --json line.
    }
    final err = '${r.stderr}'.trim();
    return err.isNotEmpty ? err : 'exit code ${r.exitCode}';
  }
}
