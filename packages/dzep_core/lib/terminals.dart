import 'dart:async';
import 'dart:io';

import 'package:dzep_core/agent.dart';
import 'package:dzep_core/apple_terminal.dart';
import 'package:dzep_core/ghostty.dart';
import 'package:dzep_core/iterm.dart';
import 'package:dzep_core/kitty.dart';
import 'package:dzep_core/terminal.dart';
import 'package:dzep_core/tmux.dart';
import 'package:dzep_core/wezterm.dart';

/// Every terminal on this Mac as one (lib/terminal.dart): their windows
/// merged (a terminal window showing tmux gives way to the tmux pane, which
/// can do more), each request routed to the window's own terminal, and new
/// windows opened where the person works.
class Terminals {
  Terminals({
    required this.kitty,
    required this.tmux,
    required this.wezterm,
    required this.iterm,
    required this.terminal,
    required this.ghostty,
    this.recency = appsByRecency,
    this.snapshot = Procs.snapshot,
  });

  /// The terminals of this Mac; kitty's sockets in [kittyDir].
  factory Terminals.standard({String kittyDir = '/tmp', String? home}) => Terminals(
    kitty: Kitty(socketDir: kittyDir, home: home),
    tmux: Tmux(),
    wezterm: WezTerm(home: home),
    iterm: ITerm(),
    terminal: AppleTerminal(),
    ghostty: Ghostty(),
  );

  final Kitty kitty;
  final Tmux tmux;
  final WezTerm wezterm;
  final ITerm iterm;
  final AppleTerminal terminal;
  final Ghostty ghostty;

  /// App names, most recently used first (`lsappinfo`); tests pass their own.
  final Future<List<String>> Function() recency;

  /// The Mac's processes now (`ps`); tests pass their own.
  final Future<Procs> Function() snapshot;

  /// In the order their windows are listed.
  List<TerminalHost> get hosts => [kitty, tmux, wezterm, iterm, terminal, ghostty];

  /// The terminal apps (tmux isn't one), in the order Auto prefers them
  /// when none was used lately.
  List<TerminalHost> get apps => [kitty, iterm, wezterm, ghostty, terminal];

  String get home => kitty.home;

  /// Terminal windows Džep opened to show a tmux session: their key → the
  /// pane's (Ghostty tells no tty to match them by).
  final _shows = <String, String>{};

  /// What each terminal said went wrong on the last [windows], by id.
  Map<String, String> problems = const {};

  TerminalHost? hostOf(String key) => hosts.where((h) => h.owns(key)).firstOrNull;

  TerminalHost _host(String key) => hostOf(key) ?? (throw const TerminalException('That window is gone.'));

  /// What window [key]'s terminal can do.
  Set<TermCap> capsOf(String key) => hostOf(key)?.caps ?? const {};

  bool can(String key, TermCap cap) => capsOf(key).contains(cap);

  /// Every window of every terminal. A terminal window attached to tmux is
  /// left out for its tmux pane, which names it as [TermWindow.via].
  Future<List<TermWindow>> windows() async {
    final procs = await snapshot();
    final problems = <String, String>{};
    final lists = await Future.wait([
      for (final h in hosts)
        h.windows(procs).catchError((Object e) {
          problems[h.id] = e is TerminalException ? e.message : '$e';
          return const <TermWindow>[];
        }),
    ]);
    this.problems = problems;
    return merge(hosts, lists, tmux.clients, _shows);
  }

  /// [lists] (one per host of [hosts]) as one list: a window whose tty is a
  /// tmux client's in [clients] (tty → pane key), or which [shows] a pane,
  /// gives way to that pane, which gets its app's label as `via`.
  static List<TermWindow> merge(
    List<TerminalHost> hosts,
    List<List<TermWindow>> lists,
    Map<String, String> clients,
    Map<String, String> shows,
  ) {
    final via = <String, String>{};
    final kept = <TermWindow>[];
    for (final (i, list) in lists.indexed) {
      final host = hosts[i];
      for (final w in list) {
        final pane = host.id == 'tmux' ? null : (shows[w.key] ?? (w.tty.isEmpty ? null : clients[w.tty]));
        if (pane != null) {
          via[pane] = host.label;
          continue;
        }
        kept.add(w);
      }
    }
    return [for (final w in kept) w.copyWith(via: via[w.key])];
  }

  /// How each installed terminal stands, for Settings and the phone.
  Future<List<TermStatus>> statuses() async {
    final procs = await snapshot();
    return await Future.wait([
      for (final h in hosts)
        h.status(procs).catchError((Object e) => TermStatus(h.id, h.label, TermState.limited, note: '$e')),
    ]);
  }

  /// Where an agent runs, from the `term` its extension reports
  /// ([windowOfTerm]); for Ghostty, which tells nothing to match, the window
  /// Džep opened on the agent's tty, else the one Ghostty window in the
  /// agent's folder [cwd] (then its tty is remembered).
  Future<String?> locate(Map<String, dynamic>? term, {String cwd = ''}) async {
    if (term == null) return null;
    final socket = term['TMUX'];
    if (socket is String && socket.isNotEmpty) tmux.learn(socket.split(',').first);
    final key = windowOfTerm(term);
    if (key != null) return key;
    if (term['TERM_PROGRAM'] != 'ghostty') return null;
    final tty = term['tty'] is String ? term['tty'] as String : '';
    final known = tty.isEmpty ? null : ghostty.byTty(tty);
    if (known != null) return known;
    final found = await ghostty.byFolder(cwd, await snapshot());
    if (found != null && tty.isNotEmpty) ghostty.learn(found, tty);
    return found;
  }

  // ------------------------------------------------------------ requests

  Future<List<String>> lines(String key, {bool history = false}) => _host(key).lines(key, history: history);

  Future<String> plainScreen(String key) => _host(key).plainScreen(key);

  Future<Map<String, Object>?> colors(String key) => _host(key).colors(key);

  Future<void> send(String key, String text, {required bool enter}) => _host(key).send(key, text, enter: enter);

  Future<void> type(String key, String text) => _host(key).type(key, text);

  Future<void> pressKeys(String key, List<String> names) => _host(key).pressKeys(key, names);

  /// One of [phoneKeys] (what the phone may press).
  Future<void> press(String key, String name) async {
    if (!phoneKeys.contains(name)) throw TerminalException('Unknown key: $name');
    await pressKeys(key, [name]);
  }

  /// Closes window [key]; for a tmux pane Džep opened a terminal window to
  /// show, that window too (Terminal keeps it open, its tmux gone), keeping
  /// the focus where it is (Ghostty comes to the front as it closes it).
  Future<void> close(String key) async {
    final guis = [
      for (final MapEntry(key: gui, value: pane) in _shows.entries)
        if (pane == key) gui,
    ];
    if (guis.isEmpty) return await _host(key).close(key);
    await keepFront(() async {
      await _host(key).close(key);
      for (final gui in guis) {
        _shows.remove(gui);
        try {
          await _host(gui).close(gui);
        } on TerminalException {
          // Already gone with its tmux (Ghostty closes it itself).
        }
      }
    }, app: hostOf(guis.first)?.bundleId);
  }

  // ------------------------------------------------------------ new windows

  /// The terminal app new windows open in: [choice] (an app's id) if it's
  /// installed; else (Auto) the running one used most recently; else the
  /// first installed of [apps].
  Future<TerminalHost> opensIn(String choice) async {
    final procs = await snapshot();
    final statuses = {
      for (final h in apps)
        h.id: await h.status(procs).catchError((Object _) => TermStatus(h.id, h.label, TermState.limited)),
    };
    return pickApp(apps, statuses, choice, await recency());
  }

  /// [opensIn]'s choice among [apps], given their [statuses] and the apps by
  /// [recency]: a chosen app that's installed; else the usable one used
  /// last; else the first usable one; else the first that can be started
  /// (kitty can't be: it must listen first).
  static TerminalHost pickApp(
    List<TerminalHost> apps,
    Map<String, TermStatus> statuses,
    String choice,
    List<String> recency,
  ) {
    final chosen = apps.where((h) => h.id == choice).firstOrNull;
    if (chosen != null && statuses[choice]?.state != TermState.missing) return chosen;
    for (final name in recency) {
      final h = apps.where((h) => h.appName == name).firstOrNull;
      if (h != null && (statuses[h.id]?.usable ?? false)) return h;
    }
    return apps.where((h) => statuses[h.id]?.usable ?? false).firstOrNull ??
        apps.where((h) => h.id != 'kitty' && statuses[h.id]?.state == TermState.idle).firstOrNull ??
        apps.last;
  }

  /// Whether a window [host] opens runs in tmux: the app can't press keys
  /// or show its screen, and tmux can.
  bool viaTmux(TerminalHost host) =>
      tmux.installed && !(host.caps.contains(TermCap.keys) && host.caps.contains(TermCap.read));

  /// How the phone names where a new session opens: "kitty", "Terminal (in tmux)".
  String describe(TerminalHost host) => viaTmux(host) ? '${host.label} (in tmux)' : host.label;

  /// A new window in [cwd] in [host] running the login shell, which then
  /// starts [agent] if given; its key (the tmux pane's, where [viaTmux]).
  Future<String> launch(String cwd, {required TerminalHost host, Agent? agent}) async {
    if (!Directory(cwd).existsSync()) throw TerminalException('No such folder: $cwd');
    final String key;
    if (viaTmux(host)) {
      key = await tmux.launch(cwd);
      try {
        final gui = await host.launch(cwd, command: tmux.attach(tmux.lastSession!));
        _shows[gui] = key;
      } on Object {
        await tmux.close(key);
        rethrow;
      }
    } else {
      key = await host.launch(cwd);
    }
    // The shell reads it once it's up: the terminal holds what's typed.
    if (agent != null) await send(key, agent.command, enter: true);
    return key;
  }

  /// Git repositories up to three levels under the usual code folders, for
  /// the phone's New session list.
  Future<List<String>> projects() async {
    final found = <String>[];
    Future<void> walk(Directory dir, int depth) async {
      final List<FileSystemEntity> entries;
      try {
        entries = await dir.list(followLinks: false).toList();
      } on FileSystemException {
        return;
      }
      if (entries.any((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty) == '.git')) {
        found.add(dir.path);
        return;
      }
      if (depth == 0) return;
      for (final e in entries) {
        final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        if (e is Directory && !name.startsWith('.') && name != 'node_modules') await walk(e, depth - 1);
      }
    }

    for (final root in ['Dev', 'Developer', 'Projects', 'code', 'src']) {
      final dir = Directory('$home/$root');
      if (dir.existsSync()) await walk(dir, 3);
    }
    return found..sort();
  }
}
