import 'dart:async';
import 'dart:math';

import 'package:dzep_core/agent.dart';
import 'package:dzep_core/ansi.dart';
import 'package:dzep_core/live.dart';
import 'package:dzep_core/native.dart';
import 'package:dzep_core/terminal.dart';
import 'package:dzep_core/terminal_remote.dart';
import 'package:dzep_core/ui.dart';
import 'package:dzep_mobile/chrome.dart';
import 'package:dzep_mobile/session_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Line height 1.2: box-drawing characters still nearly join up.
const _mono = TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['Courier'], fontSize: 11, height: 1.2);
const _monoStrut = StrutStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['Courier'],
  fontSize: 11,
  height: 1.2,
  forceStrutHeight: true,
);
const double _lineHeight = 11 * 1.2;

/// Shows what went wrong at the bottom of the screen.
void termToast(BuildContext context, Object e) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(e is TerminalException ? e.message : '$e')));

/// `/Users/me/Dev/x` as `~/Dev/x`.
String shortPath(TerminalRemote r, String path) =>
    r.home.isNotEmpty && path.startsWith(r.home) ? '~${path.substring(r.home.length)}' : path;

/// A folder's last part: the project.
String baseName(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// How long ago [t] was: "just now", "5 min ago", "3 h ago", "2 d ago".
String ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// How people name a window's terminal app ([TermWindow.app]).
String termLabel(String app) => switch (app) {
  'kitty' => 'kitty',
  'tmux' => 'tmux',
  'wezterm' => 'WezTerm',
  'iterm' => 'iTerm2',
  'terminal' => 'Terminal',
  'ghostty' => 'Ghostty',
  _ => app,
};

/// Which terminal [w] is in: "iTerm2", or "tmux · iTerm2" for a tmux pane
/// shown in iTerm2.
String termBadge(TermWindow w) => w.app == 'tmux' && w.via.isNotEmpty ? 'tmux · ${w.via}' : termLabel(w.app);

/// [termBadge] as a small rounded label.
class TermBadge extends StatelessWidget {
  const TermBadge(this.window, {super.key});
  final TermWindow window;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: const Color(0xFF262833),
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: C.line2),
    ),
    child: Text(termBadge(window), style: const TextStyle(fontSize: 11, color: C.dim, height: 1.3)),
  );
}

/// A list row's line after [w]'s badge, when the window is known.
Widget _badged(TermWindow? w, Widget line) => w == null
    ? line
    : Row(
        children: [
          TermBadge(w),
          const SizedBox(width: 6),
          Expanded(child: line),
        ],
      );

/// Closes [w] on the Mac (callers ask first: [CloseConfirm]); true once it's
/// closed.
Future<bool> closeWindow(BuildContext context, TerminalRemote remote, TermWindow w) async {
  try {
    await remote.close(w.key);
    return true;
  } on Object catch (e) {
    if (context.mounted) termToast(context, e);
    return false;
  }
}

/// Asks in place, before [window] closes: it closes on the Mac, and what runs
/// in it ends with it; [closing]: the close went, and the Mac hasn't answered.
class CloseConfirm extends StatelessWidget {
  const CloseConfirm({
    required this.remote,
    required this.window,
    required this.onKeep,
    required this.onClose,
    this.closing = false,
    super.key,
  });
  final TerminalRemote remote;
  final TermWindow window;
  final VoidCallback onKeep;
  final VoidCallback onClose;
  final bool closing;

  @override
  Widget build(BuildContext context) {
    final agent = window.agent;
    final what = agent != null
        ? 'The ${agent.label} session'
        : (window.program.isEmpty ? 'What runs in it' : window.program);
    final where = window.cwd.isEmpty ? '' : ' in ${shortPath(remote, window.cwd)}';
    return Container(
      key: ValueKey('confirm-close-${window.key}'),
      color: const Color(0x557F1D1D),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Close this window on the Mac?',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15),
                ),
                Text(
                  '$what$where ends with it.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: C.dim, height: 1.3),
                ),
              ],
            ),
          ),
          TextButton(
            key: const ValueKey('close-keep'),
            onPressed: closing ? null : onKeep,
            child: Text('Keep', style: TextStyle(color: closing ? C.dim2 : C.dim)),
          ),
          if (closing)
            const Padding(
              key: ValueKey('close-sent'),
              padding: EdgeInsets.symmetric(horizontal: 22),
              child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            TextButton(
              key: const ValueKey('close-confirm'),
              onPressed: onClose,
              child: const Text('Close', style: TextStyle(color: Color(0xFFFCA5A5))),
            ),
        ],
      ),
    );
  }
}

/// What's wrong with the link, if anything, as one line for the top of a
/// screen (on [color]: a bar by default); with how old the shown state is when
/// it isn't live.
Widget? linkNote(TerminalRemote r, {Color color = C.bar}) {
  final at = r.stateAt;
  final (text, busy) = switch (r.link) {
    TerminalLink.connecting => ('connecting…', true),
    TerminalLink.waiting => ('asking the Mac…', true),
    TerminalLink.offline => (
      "the Mac isn't answering. It has to be awake (lid open), with Džep running and "
          'Settings → Terminal from phone on.',
      false,
    ),
    TerminalLink.online => (r.error, false),
  };
  if (text == null) return null;
  final line = r.link == TerminalLink.online
      ? text
      : at != null
      ? 'Updated ${ago(at)} · $text'
      : '${text[0].toUpperCase()}${text.substring(1)}';
  return Container(
    color: color,
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
    child: Row(
      children: [
        if (busy) ...[
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(line, style: const TextStyle(fontSize: 13, color: C.dim, height: 1.4)),
        ),
      ],
    ),
  );
}

/// Opens coding session [key]; [starting]: it was just launched and its agent
/// may not have reported yet.
void openSession(BuildContext context, TerminalRemote remote, String key, {bool starting = false}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionPage(remote: remote, sessionKey: key, starting: starting),
      ),
    );

/// Opens terminal window [window]'s screen.
void openWindow(BuildContext context, TerminalRemote remote, String window) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => TerminalPage(remote: remote, window: window),
  ),
);

/// Asks where to start a session, starts it and opens it.
Future<void> openNewSession(BuildContext context, TerminalRemote remote) async {
  final launched = await showModalBottomSheet<({String window, bool agent})>(
    context: context,
    isScrollControlled: true,
    backgroundColor: C.bar,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => NewSessionSheet(remote: remote),
  );
  if (launched == null || !context.mounted) return;
  if (launched.agent) {
    // An agent the phone started: its session's key is its window's.
    openSession(context, remote, launched.window, starting: true);
  } else {
    openWindow(context, remote, launched.window);
  }
}

/// Sessions in the list's order: waiting on the person, then working, then
/// the most recent.
List<LiveSummary> sortedSessions(List<LiveSummary> sessions) {
  int rank(LiveSummary s) => s.ask != null ? 0 : (s.busy ? 1 : 2);
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  return [...sessions]..sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : (b.at ?? epoch).compareTo(a.at ?? epoch);
  });
}

/// The sessions in one project folder.
typedef SessionGroup = ({String cwd, List<LiveSummary> sessions});

/// Sessions by project folder: each group's in [sortedSessions] order, and a
/// group ranks where its first (most urgent) session does.
List<SessionGroup> groupedSessions(List<LiveSummary> sessions) {
  final groups = <String, List<LiveSummary>>{};
  for (final s in sortedSessions(sessions)) {
    (groups[s.cwd] ??= []).add(s);
  }
  return [for (final MapEntry(:key, :value) in groups.entries) (cwd: key, sessions: value)];
}

/// "Needs you", "Working…" or how long it has been idle.
String sessionState(LiveSummary s) => s.ask != null
    ? 'Needs you'
    : s.busy
    ? 'Working…'
    : (s.at == null ? 'Idle' : ago(s.at!));

Color sessionColor(LiveSummary s) => s.ask != null ? C.warn : (s.busy ? C.accent : C.dim2);

/// The Terminal tab's body: the Mac's coding sessions by project, each with
/// its + for a new one there, and its other terminal windows.
class TerminalList extends StatefulWidget {
  const TerminalList({required this.remote, required this.folded, required this.onFolded, super.key});
  final TerminalRemote remote;

  /// Projects (folders) showing only their heading, as kept; [onFolded]
  /// keeps them when they change.
  final Set<String> folded;
  final ValueChanged<Set<String>> onFolded;

  @override
  State<TerminalList> createState() => _TerminalListState();
}

class _TerminalListState extends State<TerminalList> {
  TerminalRemote get remote => widget.remote;

  late final Set<String> _folded = {...widget.folded};

  /// The project a new session is starting in.
  String? _launching;

  /// The window whose row asks whether to close it; it stops asking after a
  /// while.
  String? _confirming;
  Timer? _confirmTimer;

  /// The windows a close went for, until the Mac answers: they can't be
  /// closed again meanwhile.
  final _closing = <String>{};

  @override
  void dispose() {
    _confirmTimer?.cancel();
    super.dispose();
  }

  void _fold(String cwd) {
    setState(() {
      if (!_folded.remove(cwd)) _folded.add(cwd);
    });
    widget.onFolded({..._folded});
  }

  /// Starts the agent in a new window in [cwd], and opens its session.
  Future<void> _launchHere(String cwd) async {
    if (_launching != null) return;
    setState(() => _launching = cwd);
    // The app's navigator, which outlives this tab if it's left meanwhile:
    // the session still opens, or what went wrong still shows.
    final nav = Navigator.of(context);
    try {
      final window = await remote.launch(cwd, startAgent: true);
      // An agent the phone started: its session's key is its window's.
      if (nav.mounted) openSession(nav.context, remote, window, starting: true);
    } on Object catch (e) {
      if (nav.mounted) termToast(nav.context, e);
    } finally {
      if (mounted) setState(() => _launching = null);
    }
  }

  void _confirm(String window) {
    _confirmTimer?.cancel();
    _confirmTimer = Timer(const Duration(seconds: 5), _keep);
    setState(() => _confirming = window);
  }

  void _keep() {
    _confirmTimer?.cancel();
    if (mounted) setState(() => _confirming = null);
  }

  Future<void> _close(TermWindow w) async {
    _keep();
    setState(() => _closing.add(w.key));
    await closeWindow(context, remote, w);
    if (mounted) setState(() => _closing.remove(w.key));
  }

  /// [child], closing [w] when swiped left: after asking, in its place.
  Widget _swipe(String key, TermWindow? w, Widget child) {
    if (w == null || !w.can(TermCap.close)) return child;
    if (_closing.contains(w.key)) {
      return CloseConfirm(remote: remote, window: w, onKeep: _keep, onClose: () {}, closing: true);
    }
    if (_confirming == w.key && remote.online) {
      return CloseConfirm(remote: remote, window: w, onKeep: _keep, onClose: () => unawaited(_close(w)));
    }
    return Dismissible(
      key: ValueKey('swipe-$key'),
      direction: remote.online ? DismissDirection.endToStart : DismissDirection.none,
      background: Container(
        color: const Color(0xFF7F1D1D),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.close, color: Colors.white),
      ),
      // The row stays: it asks in place.
      confirmDismiss: (_) async {
        _confirm(w.key);
        return false;
      },
      child: child,
    );
  }

  /// A session's row; its project is the heading above it.
  Widget _session(LiveSummary s) {
    final title = s.title.isNotEmpty ? s.title : s.agent.label;
    final w = s.window == null ? null : remote.window(s.window!);
    return _swipe(
      s.key,
      w,
      ListTile(
        key: ValueKey('session-${s.key}'),
        onTap: () => openSession(context, remote, s.key),
        leading: Icon(Icons.auto_awesome, size: 18, color: sessionColor(s)),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _badged(
              w,
              Text(
                sessionState(s),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: s.ask != null || s.busy ? sessionColor(s) : C.dim),
              ),
            ),
            if (s.preview.isNotEmpty)
              Text(
                s.preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: C.dim2),
              ),
          ],
        ),
      ),
    );
  }

  /// A project's sessions under its heading: folds on tap, and its + starts
  /// the agent there.
  Widget _project(SessionGroup g) {
    final folded = _folded.contains(g.cwd);
    return Panel(
      key: ValueKey('project-${g.cwd}'),
      title: (g.cwd.isEmpty ? 'Somewhere' : baseName(g.cwd)).toUpperCase(),
      count: g.sessions.length,
      onTitleTap: () => _fold(g.cwd),
      titleTrailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Folded, a session needing you would go unseen.
          if (folded && g.sessions.any((s) => s.ask != null))
            Padding(
              key: ValueKey('project-needs-you-${g.cwd}'),
              padding: const EdgeInsets.only(right: 6),
              child: const Icon(Icons.circle, size: 8, color: C.warn),
            ),
          // Somewhere unknown has nowhere to start one.
          if (g.cwd.isNotEmpty)
            // Its own taps, also while it's off or starting: they never fold
            // the project.
            GestureDetector(
              key: ValueKey('project-new-${g.cwd}'),
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: SizedBox(
                width: 44,
                height: 32,
                child: _launching == g.cwd
                    ? const Center(
                        child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : IconButton(
                        key: ValueKey('new-in-${g.cwd}'),
                        padding: EdgeInsets.zero,
                        iconSize: 22,
                        tooltip: 'New ${remote.agent.label} session here',
                        onPressed: remote.online && _launching == null ? () => unawaited(_launchHere(g.cwd)) : null,
                        icon: Icon(isIos ? Icons.add_rounded : Icons.add),
                        color: C.accent,
                      ),
              ),
            ),
          // As Pocket's Done: down while folded.
          Icon(folded ? Icons.expand_more : Icons.expand_less, color: C.dim, size: 20),
        ],
      ),
      children: folded ? const [] : [for (final s in g.sessions) _session(s)],
    );
  }

  Widget _window(TermWindow w) => _swipe(
    w.key,
    w,
    ListTile(
      key: ValueKey('term-${w.key}'),
      onTap: () => openWindow(context, remote, w.key),
      leading: Icon(
        w.agent != null ? Icons.auto_awesome : Icons.terminal,
        size: 18,
        color: w.focused ? C.accent : C.dim2,
      ),
      title: Text(
        w.title.isEmpty ? w.program : w.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15),
      ),
      subtitle: _badged(
        w,
        Text(
          '${w.program} · ${shortPath(remote, w.cwd)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, color: C.dim),
        ),
      ),
    ),
  );

  /// Nothing runs: where a new session opens, and what each terminal that
  /// isn't ready needs (tmux: when it isn't installed).
  Widget _empty() {
    final online = remote.online;
    final unready = [
      for (final t in remote.terminals)
        if (t.state != TermState.ready && (t.state != TermState.missing || t.id == 'tmux')) t,
    ];
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        children: [
          Text(
            online && remote.error == null
                ? 'Nothing runs in ${remote.opensIn ?? 'your terminal'}. Tap + to start ${remote.agent.label}.'
                : '',
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.dim, height: 1.5),
          ),
          if (online)
            for (final t in unready)
              Padding(
                key: ValueKey('terminal-${t.id}'),
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '${t.label}: ${t.note.isNotEmpty ? t.note : _stateWord(t.state)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: C.dim2, height: 1.4),
                ),
              ),
        ],
      ),
    );
  }

  static String _stateWord(TermState s) => switch (s) {
    TermState.ready => 'ready',
    TermState.limited => 'limited',
    TermState.setup => 'needs setup on the Mac',
    TermState.idle => 'not running',
    TermState.missing => 'not installed',
  };

  @override
  Widget build(BuildContext context) => _KeepAwake(child: _list());

  Widget _list() => ListenableBuilder(
    listenable: remote,
    builder: (context, _) {
      final note = linkNote(remote, color: Colors.transparent);
      final groups = groupedSessions(remote.sessions);
      final claimed = {for (final s in remote.sessions) ?s.window};
      final windows = remote.windows.where((w) => !claimed.contains(w.key)).toList();
      // The sessions and windows, in each platform's grouped cards.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (note != null) Panel(children: [note]),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                remote.hello();
                await Future<void>.delayed(const Duration(milliseconds: 600));
              },
              child: ListView(
                padding: const EdgeInsets.only(bottom: AppTabBar.contentInset),
                children: [
                  if (groups.isEmpty && windows.isEmpty) _empty(),
                  for (final g in groups) _project(g),
                  if (windows.isNotEmpty) ...[
                    Panel(title: groups.isEmpty ? 'WINDOWS' : 'OTHER WINDOWS', children: const []),
                    // An agent whose Džep integration doesn't report: out of date, or installed after it started.
                    for (final agent in Agent.values)
                      if (windows.any((w) => w.agent == agent))
                        Padding(
                          key: ValueKey('${agent.command}-screens-only'),
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                          child: Text(switch (agent) {
                            Agent.omp =>
                              'These omp windows show only as screens: Džep’s omp extension isn’t reporting from '
                                  'them. It may be out of date (update it in Džep’s Settings on the Mac), or omp there '
                                  'started before it was installed. Then quit omp there and start it again (omp -c '
                                  'picks the conversation back up) to see it above, as a conversation.',
                            Agent.claude =>
                              'These Claude windows show only as screens: Džep’s Claude Code plugin isn’t reporting '
                                  'from them. It may be out of date (update it in Džep’s Settings on the Mac), or '
                                  'Claude there started before it was installed. Then quit Claude there and start it '
                                  'again (claude -c picks the conversation back up) to see it above, as a conversation.',
                          }, style: const TextStyle(fontSize: 12, color: C.dim2, height: 1.4)),
                        ),
                    Panel(children: [for (final w in windows) _window(w)]),
                  ],
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// The screen stays on while the Terminal tab is up (and the session and
/// screen pages pushed over it): a terminal is something you watch.
class _KeepAwake extends StatefulWidget {
  const _KeepAwake({required this.child});
  final Widget child;

  @override
  State<_KeepAwake> createState() => _KeepAwakeState();
}

class _KeepAwakeState extends State<_KeepAwake> {
  @override
  void initState() {
    super.initState();
    unawaited(Native.setKeepAwake(on: true));
  }

  @override
  void dispose() {
    unawaited(Native.setKeepAwake(on: false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// One terminal window: its screen as text, live, plus a composer and the
/// keys a terminal program needs (a coding agent's menus: arrows, Enter, Esc),
/// each as far as the window's terminal allows.
class TerminalPage extends StatefulWidget {
  const TerminalPage({required this.remote, required this.window, super.key});
  final TerminalRemote remote;
  final String window;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _field = TextEditingController();
  final _scroll = ScrollController();
  late final VoidCallback _unwatch;

  /// A shell's long lines reflow to the phone's width; a full-screen program
  /// (a coding agent) lays out to its own width, so its lines stay whole.
  late bool _wrap = remote.window(widget.window)?.agent == null;
  bool _sending = false;

  /// The close button was tapped: the page asks above its bar.
  bool _closing = false;

  /// A close was sent, and the Mac hasn't answered yet.
  bool _closeSent = false;

  /// Lines numbered from the first one the phone saw: the ones from
  /// [_anchor] on go below the scroll view's center, so lines arriving
  /// there never move what's above.
  int? _anchor;
  bool _atBottom = true;

  /// Each line's spans and visible length, for [_palette].
  final _spans = <String, (List<TextSpan>, int)>{};
  TermColors? _palette;

  TerminalRemote get remote => widget.remote;

  @override
  void initState() {
    super.initState();
    _field.addListener(() => setState(() {}));
    _scroll.addListener(() {
      final p = _scroll.position;
      _atBottom = p.pixels >= p.maxScrollExtent - 8;
    });
    _unwatch = remote.watchWindow(widget.window);
  }

  @override
  void dispose() {
    _unwatch();
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _field.text;
    if (text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await remote.send(widget.window, text);
      _field.clear();
    } on Object catch (e) {
      if (mounted) termToast(context, e);
    }
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _close(TermWindow w) async {
    setState(() => _closeSent = true);
    final closed = await closeWindow(context, remote, w);
    if (!mounted) return;
    setState(() => _closing = _closeSent = false);
    if (closed) await Navigator.of(context).maybePop();
  }

  Future<void> _press(String key) async {
    unawaited(HapticFeedback.selectionClick());
    try {
      await remote.press(widget.window, key);
    } on Object catch (e) {
      if (mounted) termToast(context, e);
    }
  }

  (List<TextSpan>, int) _line(String line, TermColors palette) {
    if (!identical(palette, _palette)) {
      _palette = palette;
      _spans.clear();
    }
    return _spans[line] ??= () {
      final spans = ansiSpans(line, palette);
      return (spans, spans.fold<int>(0, (n, s) => n + (s.text?.length ?? 0)));
    }();
  }

  Widget _key(String label, String key) => Expanded(
    child: TextFieldTapRegion(
      child: InkWell(
        key: ValueKey('key-$key'),
        onTap: () => unawaited(_press(key)),
        borderRadius: BorderRadius.circular(7),
        child: Container(
          height: 34,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF262833),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: C.line2),
          ),
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
      ),
    ),
  );

  void _followBottom() {
    if (!_atBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final p = _scroll.position;
      if (p.pixels != p.maxScrollExtent) _scroll.jumpTo(p.maxScrollExtent);
    });
  }

  Widget _screen(TermScreen s, TermColors palette) {
    final lines = s.lines;
    final end = s.base + lines.length;
    // A cleared screen: start over at its end.
    final anchor = _anchor = (_anchor == null || _anchor! > end) ? end : _anchor!;
    final above = (anchor - s.base).clamp(0, lines.length);
    final style = _mono.copyWith(color: palette.foreground);
    var widest = 0;
    if (!_wrap) {
      for (final l in lines) {
        final n = _line(l, palette).$2;
        if (n > widest) widest = n;
      }
    }

    Widget row(int i) {
      final text = Text.rich(
        TextSpan(children: _line(lines[i], palette).$1),
        style: style,
        strutStyle: _monoStrut,
        softWrap: _wrap,
        maxLines: _wrap ? null : 1,
      );
      return Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: text);
    }

    const center = ValueKey('center');
    SliverChildBuilderDelegate delegate(int count, int Function(int) at) =>
        SliverChildBuilderDelegate((_, i) => row(at(i)), childCount: count);
    Widget sliver(int count, int Function(int) at, {Key? key}) => _wrap
        ? SliverList(key: key, delegate: delegate(count, at))
        : SliverFixedExtentList(key: key, itemExtent: _lineHeight, delegate: delegate(count, at));

    _followBottom();
    final view = CustomScrollView(
      controller: _scroll,
      center: center,
      // The center at the bottom: the screen's end shows first.
      anchor: 1,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        // Before the center: laid out upwards from it.
        sliver(above, (i) => above - 1 - i),
        sliver(lines.length - above, (i) => above + i, key: center),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
      ],
    );
    return ColoredBox(
      color: palette.background,
      child: SelectionArea(
        child: _wrap
            ? view
            : LayoutBuilder(
                builder: (context, box) {
                  final tp = TextPainter(
                    text: const TextSpan(text: 'M', style: _mono),
                    textDirection: TextDirection.ltr,
                  )..layout();
                  final width = tp.width * widest + 24;
                  tp.dispose();
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(width: width < box.maxWidth ? box.maxWidth : width, child: view),
                  );
                },
              ),
      ),
    );
  }

  /// Why [w]'s screen doesn't show, and what would show it.
  Widget _unreadable(TermWindow w) {
    final tmux = remote.terminals.where((t) => t.id == 'tmux').firstOrNull;
    final fix = tmux != null && tmux.state == TermState.missing
        ? tmux.note
        : 'Sessions you start from the phone open in tmux, which can.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "${termLabel(w.app)} can't share its screen.",
              key: const ValueKey('screen-unreadable'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: C.dim, height: 1.5),
            ),
            const SizedBox(height: 8),
            Text(
              fix,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: C.dim2, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  /// The keys a terminal program needs, if the window's terminal can press
  /// them, and the composer, if it can type.
  Widget _bar({required bool enabled, required bool keys, required bool compose, required bool canSend}) => Container(
    decoration: const BoxDecoration(
      color: C.bar,
      border: Border(top: BorderSide(color: C.line)),
    ),
    padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (keys && enabled)
            Padding(
              padding: EdgeInsets.only(bottom: compose ? 8 : 0, right: 4),
              child: Row(
                children: [
                  _key('Esc', 'esc'),
                  _key('Tab', 'tab'),
                  _key('↑', 'up'),
                  _key('↓', 'down'),
                  _key('⏎', 'enter'),
                  _key('^C', 'ctrl+c'),
                ],
              ),
            ),
          if (compose)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    key: const ValueKey('term-input'),
                    onTapOutside: dismissKeyboard,
                    controller: _field,
                    minLines: 1,
                    maxLines: 6,
                    enabled: enabled,
                    autocorrect: false,
                    style: const TextStyle(fontSize: 16, height: 1.4),
                    decoration: plainInput.copyWith(
                      hintText: 'Type a line…',
                      hintStyle: const TextStyle(color: C.dim2),
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                // Part of the field for tap-outside: sending keeps the
                // keyboard up for the next line.
                TextFieldTapRegion(
                  child: IconButton(
                    key: const ValueKey('term-send'),
                    tooltip: 'Send (types it, then Enter)',
                    onPressed: canSend ? () => unawaited(_send()) : null,
                    icon: _sending
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.arrow_upward, color: canSend ? C.accent : C.dim2),
                  ),
                ),
              ],
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: remote,
    builder: (context, _) {
      final w = remote.window(widget.window);
      final online = remote.online;
      final gone = online && !remote.fromCache && w == null;
      final screen = remote.screen(widget.window);
      final palette = remote.colors[widget.window] ?? TermColors.fallback;
      final note = linkNote(remote);
      // A window not in the list yet (just launched) can do everything.
      bool can(TermCap c) => w?.can(c) ?? true;
      final readable = can(TermCap.read);
      final keys = can(TermCap.keys);
      final compose = can(TermCap.line) || can(TermCap.type);
      final canSend = online && !gone && !_sending && _field.text.trim().isNotEmpty;
      return Scaffold(
        appBar: AppBar(
          backgroundColor: C.win,
          title: Text(
            w == null ? 'Terminal' : (w.title.isEmpty ? w.program : w.title),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (w != null && online && w.can(TermCap.close))
              IconButton(
                key: const ValueKey('close-window'),
                tooltip: 'Close window',
                onPressed: _closeSent ? null : () => setState(() => _closing = true),
                icon: const Icon(Icons.close, color: C.dim),
              ),
            if (readable)
              IconButton(
                tooltip: _wrap ? "Don't wrap lines" : 'Wrap lines',
                onPressed: () => setState(() => _wrap = !_wrap),
                icon: Icon(Icons.wrap_text, color: _wrap ? C.accent : C.dim),
              ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?note,
            Expanded(
              child: gone
                  ? const Center(
                      child: Text('This window has closed.', style: TextStyle(color: C.dim)),
                    )
                  : !readable
                  ? _unreadable(w!)
                  : screen == null
                  ? Center(
                      child: online
                          ? const CircularProgressIndicator(strokeWidth: 2)
                          : const Text('No screen yet.', style: TextStyle(color: C.dim)),
                    )
                  : _screen(screen, palette),
            ),
            if (_closing && w != null && online && !gone)
              CloseConfirm(
                remote: remote,
                window: w,
                onKeep: () => setState(() => _closing = false),
                onClose: () => unawaited(_close(w)),
                closing: _closeSent,
              ),
            if (keys || compose) _bar(enabled: online && !gone, keys: keys, compose: compose, canSend: canSend),
          ],
        ),
      );
    },
  );
}

/// A new terminal window in one of the Mac's projects (or any folder typed in),
/// or in a new project folder made under one of the Mac's Project folders,
/// starting the Mac's coding agent unless turned off. Pops the new window's
/// key and whether the agent runs in it.
class NewSessionSheet extends StatefulWidget {
  const NewSessionSheet({required this.remote, super.key});
  final TerminalRemote remote;

  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<NewSessionSheet> {
  final _query = TextEditingController();
  bool _agent = true;
  String? _launching;

  /// Making a new project: its [_name] and the Mac's root it goes in (the
  /// first while none is picked or the picked one is gone).
  bool _creating = false;
  final _name = TextEditingController();
  String? _rootPath;

  TerminalRemote get remote => widget.remote;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    _name.dispose();
    super.dispose();
  }

  InputDecoration _field(String hint, IconData icon) => InputDecoration(
    hintText: hint,
    prefixIcon: Icon(icon, size: 20, color: C.dim),
    filled: true,
    fillColor: C.field,
    isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
  );

  /// `~/x` and `/x` typed in, as the Mac's path.
  String? get _typed {
    final q = _query.text.trim();
    if (q.startsWith('~')) return '${remote.home}${q.substring(1)}';
    return q.startsWith('/') ? q : null;
  }

  Future<void> _launch(String cwd) async {
    if (_launching != null) return;
    setState(() => _launching = cwd);
    try {
      final agent = _agent;
      final window = await remote.launch(cwd, startAgent: agent);
      if (mounted) Navigator.of(context).pop((window: window, agent: agent));
    } on Object catch (e) {
      if (mounted) {
        setState(() => _launching = null);
        termToast(context, e);
      }
    }
  }

  /// Makes [_name] under [root] on the Mac and opens a window there, as [_launch].
  Future<void> _create(String root) async {
    if (_launching != null) return;
    setState(() => _launching = root);
    try {
      final agent = _agent;
      final window = await remote.create(root, _name.text.trim(), startAgent: agent);
      if (mounted) Navigator.of(context).pop((window: window, agent: agent));
    } on Object catch (e) {
      if (mounted) {
        setState(() => _launching = null);
        termToast(context, e);
      }
    }
  }

  /// Name the project and pick the folder it goes in.
  List<Widget> _createForm(Widget? note) {
    final roots = remote.roots ?? const <String>[];
    final root = roots.contains(_rootPath) ? _rootPath : roots.firstOrNull;
    final busy = _launching != null;
    final ready = remote.online && _name.text.trim().isNotEmpty && !busy;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: TextField(
          key: const ValueKey('project-name'),
          onTapOutside: dismissKeyboard,
          controller: _name,
          autofocus: true,
          autocorrect: false,
          style: const TextStyle(fontSize: 15),
          decoration: _field('Project name', Icons.create_new_folder_outlined),
        ),
      ),
      ?note,
      Expanded(
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            const Text('In', style: TextStyle(fontSize: 12, color: C.dim)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in roots)
                  ChoiceChip(
                    label: Text(shortPath(remote, r)),
                    selected: r == root,
                    onSelected: (_) => setState(() => _rootPath = r),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(onPressed: busy ? null : () => setState(() => _creating = false), child: const Text('Back')),
                const Spacer(),
                FilledButton(
                  onPressed: root != null && ready ? () => unawaited(_create(root)) : null,
                  child: busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Create and open'),
                ),
              ],
            ),
          ],
        ),
      ),
    ];
  }

  /// Find a project (or type a path) and open a window there; or start a
  /// new project.
  List<Widget> _pickList(Widget? note) {
    final words = _query.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final open = {for (final w in remote.windows) w.cwd};
    final places = [
      ...open.where((p) => p.isNotEmpty && p != remote.home),
      ...remote.projects.where((p) => !open.contains(p)),
    ].where((p) => words.every(shortPath(remote, p).toLowerCase().contains)).toList();
    final typed = _typed;
    // null: a Mac that predates Project folders, and can't make a project.
    final roots = remote.roots;
    final noRoots = roots != null && roots.isEmpty;
    final noRootsHint = remote.online && noRoots && places.isEmpty && typed == null;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: TextField(
          key: const ValueKey('session-folder'),
          onTapOutside: dismissKeyboard,
          controller: _query,
          autocorrect: false,
          style: const TextStyle(fontSize: 15),
          decoration: _field('Find a project, or type ~/path', Icons.folder_outlined),
        ),
      ),
      ?note,
      if (noRootsHint)
        const Padding(
          key: ValueKey('no-roots'),
          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            'No project folders yet. On your Mac, open Džep → Settings → Project folders and add '
            'the folders that hold your projects. You can still type a ~/path above.',
            style: TextStyle(fontSize: 13, color: C.dim, height: 1.4),
          ),
        ),
      Expanded(
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            if (_query.text.isEmpty && roots != null)
              ListTile(
                key: const ValueKey('new-project'),
                dense: true,
                enabled: remote.online && roots.isNotEmpty && _launching == null,
                onTap: () => setState(() => _creating = true),
                leading: const Icon(Icons.create_new_folder_outlined, size: 18, color: C.dim2),
                title: const Text('New project…', style: TextStyle(fontSize: 14)),
                // The hint above says it already.
                subtitle: noRoots && !noRootsHint
                    ? const Text(
                        'Add a project folder in Džep on your Mac: Settings → Project folders',
                        style: TextStyle(fontSize: 12, color: C.dim),
                      )
                    : null,
              ),
            for (final p in [?typed, ...places])
              ListTile(
                dense: true,
                enabled: remote.online,
                onTap: () => unawaited(_launch(p)),
                leading: Icon(open.contains(p) ? Icons.terminal : Icons.folder_outlined, size: 18, color: C.dim2),
                title: Text(shortPath(remote, p), style: const TextStyle(fontSize: 14)),
                trailing: _launching == p
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
              ),
          ],
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: remote,
    builder: (context, _) {
      final note = linkNote(remote);
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          child: SizedBox(
            // 70% of the screen, less whatever the keyboard leaves no room for.
            height: min(
              MediaQuery.sizeOf(context).height * .7,
              MediaQuery.sizeOf(context).height -
                  MediaQuery.viewInsetsOf(context).bottom -
                  MediaQuery.paddingOf(context).top -
                  24,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 18, 20, remote.opensIn == null ? 4 : 0),
                  child: Text(
                    _creating ? 'New project' : 'New session',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                if (remote.opensIn case final opensIn?)
                  Padding(
                    key: const ValueKey('opens-in'),
                    padding: const EdgeInsets.fromLTRB(20, 2, 20, 4),
                    child: Text('Opens in $opensIn', style: const TextStyle(fontSize: 13, color: C.dim)),
                  ),
                SwitchListTile(
                  key: const ValueKey('start-agent'),
                  value: _agent,
                  onChanged: (v) => setState(() => _agent = v),
                  title: Text('Start ${remote.agent.label}', style: const TextStyle(fontSize: 15)),
                  subtitle: const Text('Off: just a shell', style: TextStyle(fontSize: 12, color: C.dim)),
                ),
                if (_creating) ..._createForm(note) else ..._pickList(note),
              ],
            ),
          ),
        ),
      );
    },
  );
}
