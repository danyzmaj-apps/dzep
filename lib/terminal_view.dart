import 'dart:async';
import 'dart:math';

import 'package:dzep/ansi.dart';
import 'package:dzep/kitty.dart';
import 'package:dzep/live.dart';
import 'package:dzep/session_view.dart';
import 'package:dzep/terminal_remote.dart';
import 'package:dzep/ui.dart';
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

void _unfocus(PointerDownEvent _) => FocusManager.instance.primaryFocus?.unfocus();

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

/// Asks, then closes [w] on the Mac; true once it's closed.
Future<bool> closeWindow(BuildContext context, TerminalRemote remote, TermWindow w) async {
  final what = w.isOmp ? 'the omp session' : (w.program.isEmpty ? 'what runs in it' : w.program);
  final sure = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Close this window?'),
      content: Text(
        'It closes on the Mac, and $what in ${shortPath(remote, w.cwd)} ends with it.',
        style: const TextStyle(color: C.dim, height: 1.4),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        TextButton(
          key: const ValueKey('close-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Close', style: TextStyle(color: Color(0xFFFCA5A5))),
        ),
      ],
    ),
  );
  if (sure != true) return false;
  try {
    await remote.close(w.key);
    return true;
  } on Object catch (e) {
    if (context.mounted) termToast(context, e);
    return false;
  }
}

/// What's wrong with the link, if anything, as one line for the top of a
/// screen; with how old the shown state is when it isn't live.
Widget? linkNote(TerminalRemote r) {
  final at = r.stateAt;
  final (text, busy) = switch (r.link) {
    TerminalLink.connecting => ('connecting…', true),
    TerminalLink.waiting => ('asking the Mac…', true),
    TerminalLink.offline => (
      "the Mac isn't answering. It has to be awake (lid open), with Džep running and "
          'Settings → Terminal from iPhone on.',
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
    color: C.bar,
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

/// Opens omp session [key]; [starting]: it was just launched and omp may
/// not have reported yet.
void openSession(BuildContext context, TerminalRemote remote, String key, {bool starting = false}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionPage(remote: remote, sessionKey: key, starting: starting),
      ),
    );

/// Opens kitty window [window]'s screen.
void openWindow(BuildContext context, TerminalRemote remote, String window) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => TerminalPage(remote: remote, window: window),
  ),
);

/// Asks where to start a session, starts it and opens it.
Future<void> openNewSession(BuildContext context, TerminalRemote remote) async {
  final launched = await showModalBottomSheet<({String window, bool omp})>(
    context: context,
    isScrollControlled: true,
    backgroundColor: C.bar,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => NewSessionSheet(remote: remote),
  );
  if (launched == null || !context.mounted) return;
  if (launched.omp) {
    // omp in kitty: its session's key is its window's.
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

/// "Needs you", "Working…" or how long it has been idle.
String sessionState(LiveSummary s) => s.ask != null
    ? 'Needs you'
    : s.busy
    ? 'Working…'
    : (s.at == null ? 'Idle' : ago(s.at!));

Color sessionColor(LiveSummary s) => s.ask != null ? C.warn : (s.busy ? C.accent : C.dim2);

/// The Terminal tab's body: the Mac's omp sessions, and its other kitty
/// windows.
class TerminalList extends StatelessWidget {
  const TerminalList({required this.remote, super.key});
  final TerminalRemote remote;

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: C.dim2, letterSpacing: .4),
    ),
  );

  Widget _swipe(BuildContext context, String key, TermWindow? w, Widget child) {
    if (w == null) return child;
    return Dismissible(
      key: ValueKey('swipe-$key'),
      direction: remote.online ? DismissDirection.endToStart : DismissDirection.none,
      background: Container(
        color: const Color(0xFF7F1D1D),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.close, color: Colors.white),
      ),
      confirmDismiss: (_) => closeWindow(context, remote, w),
      child: child,
    );
  }

  Widget _session(BuildContext context, LiveSummary s) {
    final title = s.title.isNotEmpty ? s.title : baseName(s.cwd);
    final w = s.window == null ? null : remote.window(s.window!);
    return _swipe(
      context,
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
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${baseName(s.cwd)} · '),
                  TextSpan(
                    text: sessionState(s),
                    style: TextStyle(color: s.ask != null || s.busy ? sessionColor(s) : null),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: C.dim),
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

  Widget _window(BuildContext context, TermWindow w) => _swipe(
    context,
    w.key,
    w,
    ListTile(
      key: ValueKey('term-${w.key}'),
      onTap: () => openWindow(context, remote, w.key),
      leading: Icon(w.isOmp ? Icons.auto_awesome : Icons.terminal, size: 18, color: w.focused ? C.accent : C.dim2),
      title: Text(
        w.title.isEmpty ? w.program : w.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15),
      ),
      subtitle: Text(
        '${w.program} · ${shortPath(remote, w.cwd)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, color: C.dim),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: remote,
    builder: (context, _) {
      final note = linkNote(remote);
      final sessions = sortedSessions(remote.sessions);
      final claimed = {for (final s in sessions) ?s.window};
      final windows = remote.windows.where((w) => !claimed.contains(w.key)).toList();
      const divider = Divider(height: 1, color: C.line, indent: 52);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?note,
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                remote.hello();
                await Future<void>.delayed(const Duration(milliseconds: 600));
              },
              child: ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  if (sessions.isEmpty && windows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(40),
                      child: Text(
                        remote.online && remote.error == null ? 'Nothing runs in kitty. Tap + to start omp.' : '',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: C.dim, height: 1.5),
                      ),
                    ),
                  if (sessions.isNotEmpty) ...[
                    _header('OMP'),
                    for (final (i, s) in sessions.indexed) ...[if (i > 0) divider, _session(context, s)],
                  ],
                  if (windows.isNotEmpty) ...[
                    _header('WINDOWS'),
                    // omp running without the live extension: started before it was installed.
                    if (windows.any((w) => w.isOmp))
                      const Padding(
                        key: ValueKey('omp-screens-only'),
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          'These omp windows show only as screens: omp in them started before its Džep '
                          'extension (live.ts) was installed. Quit omp there and start it again (omp -c picks '
                          'the conversation back up) to see it above, as a conversation.',
                          style: TextStyle(fontSize: 12, color: C.dim2, height: 1.4),
                        ),
                      ),
                    for (final (i, w) in windows.indexed) ...[if (i > 0) divider, _window(context, w)],
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

/// One kitty window: its screen as text, live, plus a composer and the keys
/// a terminal program needs (omp's menus: arrows, Enter, Esc).
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
  /// (omp) lays out to its own width, so its lines stay whole.
  late bool _wrap = !(remote.window(widget.window)?.isOmp ?? false);
  bool _sending = false;

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
            if (w != null && online)
              IconButton(
                key: const ValueKey('close-window'),
                tooltip: 'Close window',
                onPressed: () => unawaited(
                  closeWindow(context, remote, w).then((closed) {
                    if (closed && context.mounted) Navigator.of(context).maybePop();
                  }),
                ),
                icon: const Icon(Icons.close, color: C.dim),
              ),
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
                  : screen == null
                  ? Center(
                      child: online
                          ? const CircularProgressIndicator(strokeWidth: 2)
                          : const Text('No screen yet.', style: TextStyle(color: C.dim)),
                    )
                  : _screen(screen, palette),
            ),
            Container(
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
                    if (online && !gone)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8, right: 4),
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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const SizedBox(width: 6),
                        Expanded(
                          child: TextField(
                            key: const ValueKey('term-input'),
                            onTapOutside: _unfocus,
                            controller: _field,
                            minLines: 1,
                            maxLines: 6,
                            enabled: online && !gone,
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
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : Icon(Icons.arrow_upward, color: canSend ? C.accent : C.dim2),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// A new kitty window in one of the Mac's projects (or any folder typed in),
/// running omp unless turned off. Pops the new window's key and whether omp
/// runs in it.
class NewSessionSheet extends StatefulWidget {
  const NewSessionSheet({required this.remote, super.key});
  final TerminalRemote remote;

  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<NewSessionSheet> {
  final _query = TextEditingController();
  bool _omp = true;
  String? _launching;

  TerminalRemote get remote => widget.remote;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

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
      final omp = _omp;
      final window = await remote.launch(cwd, omp: omp);
      if (mounted) Navigator.of(context).pop((window: window, omp: omp));
    } on Object catch (e) {
      if (mounted) {
        setState(() => _launching = null);
        termToast(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: remote,
    builder: (context, _) {
      final words = _query.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
      final open = {for (final w in remote.windows) w.cwd};
      final places = [
        ...open.where((p) => p.isNotEmpty && p != remote.home),
        ...remote.projects.where((p) => !open.contains(p)),
      ].where((p) => words.every(shortPath(remote, p).toLowerCase().contains)).toList();
      final typed = _typed;
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
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 18, 20, 4),
                  child: Text('New session', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                SwitchListTile(
                  key: const ValueKey('start-omp'),
                  value: _omp,
                  onChanged: (v) => setState(() => _omp = v),
                  title: const Text('Start omp', style: TextStyle(fontSize: 15)),
                  subtitle: const Text('Off: just a shell', style: TextStyle(fontSize: 12, color: C.dim)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    key: const ValueKey('session-folder'),
                    onTapOutside: _unfocus,
                    controller: _query,
                    autocorrect: false,
                    style: const TextStyle(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: 'Find a project, or type ~/path',
                      prefixIcon: const Icon(Icons.folder_outlined, size: 20, color: C.dim),
                      filled: true,
                      fillColor: C.field,
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                ?note,
                Expanded(
                  child: ListView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    children: [
                      for (final p in [?typed, ...places])
                        ListTile(
                          dense: true,
                          enabled: remote.online,
                          onTap: () => unawaited(_launch(p)),
                          leading: Icon(
                            open.contains(p) ? Icons.terminal : Icons.folder_outlined,
                            size: 18,
                            color: C.dim2,
                          ),
                          title: Text(shortPath(remote, p), style: const TextStyle(fontSize: 14)),
                          trailing: _launching == p
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : null,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
