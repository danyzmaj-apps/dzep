import 'dart:async';

import 'package:dzep/ansi.dart';
import 'package:dzep/kitty.dart';
import 'package:dzep/terminal.dart';
import 'package:dzep/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Line height 1.2: box-drawing characters still nearly join up.
const _mono = TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['Courier'], fontSize: 11, height: 1.2);

void _unfocus(PointerDownEvent _) => FocusManager.instance.primaryFocus?.unfocus();

void _toast(BuildContext context, Object e) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(e is TerminalException ? e.message : '$e')));

/// `/Users/me/Dev/x` as `~/Dev/x`.
String _short(TerminalRemote r, String path) =>
    r.home.isNotEmpty && path.startsWith(r.home) ? '~${path.substring(r.home.length)}' : path;

/// What's wrong with the link, if anything, as one line for the top of a screen.
Widget? _linkNote(TerminalRemote r) {
  final (text, busy) = switch (r.link) {
    TerminalLink.connecting => ('Connecting…', true),
    TerminalLink.waiting => ('Asking the Mac…', true),
    TerminalLink.offline => (
      "The Mac isn't answering. It has to be awake (lid open), with Džep running and "
          'Settings → Terminal from iPhone on.',
      false,
    ),
    TerminalLink.online => (r.error, false),
  };
  if (text == null) return null;
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
          child: Text(text, style: const TextStyle(fontSize: 13, color: C.dim, height: 1.4)),
        ),
      ],
    ),
  );
}

/// The Terminal tab's body: the Mac's kitty windows.
class TerminalList extends StatefulWidget {
  const TerminalList({required this.remote, required this.onOpen, super.key});
  final TerminalRemote remote;
  final void Function(String window) onOpen;

  @override
  State<TerminalList> createState() => _TerminalListState();
}

class _TerminalListState extends State<TerminalList> {
  TerminalRemote get remote => widget.remote;

  @override
  void initState() {
    super.initState();
    remote.attach();
  }

  @override
  void dispose() {
    remote.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: remote,
    builder: (context, _) {
      final note = _linkNote(remote);
      final windows = remote.link == TerminalLink.online ? remote.windows : const <TermWindow>[];
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
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: windows.isEmpty ? 1 : windows.length,
                separatorBuilder: (_, _) => const Divider(height: 1, color: C.line, indent: 52),
                itemBuilder: (context, i) {
                  if (windows.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(40),
                      child: Text(
                        remote.link == TerminalLink.online && remote.error == null
                            ? 'No kitty windows. Tap + to open one.'
                            : '',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: C.dim, height: 1.5),
                      ),
                    );
                  }
                  final w = windows[i];
                  return ListTile(
                    key: ValueKey('term-${w.key}'),
                    onTap: () => widget.onOpen(w.key),
                    leading: Icon(
                      w.isOmp ? Icons.auto_awesome : Icons.terminal,
                      size: 18,
                      color: w.focused ? C.accent : C.dim2,
                    ),
                    title: Text(
                      w.title.isEmpty ? w.program : w.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15),
                    ),
                    subtitle: Text(
                      '${w.program} · ${_short(remote, w.cwd)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: C.dim),
                    ),
                  );
                },
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
  bool _wrap = true;
  bool _sending = false;

  TerminalRemote get remote => widget.remote;

  @override
  void initState() {
    super.initState();
    _field.addListener(() => setState(() {}));
    remote
      ..attach()
      ..watch(widget.window);
  }

  @override
  void dispose() {
    remote
      ..watch(null)
      ..detach();
    _field.dispose();
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
      if (mounted) _toast(context, e);
    }
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _press(String key) async {
    unawaited(HapticFeedback.selectionClick());
    try {
      await remote.press(widget.window, key);
    } on Object catch (e) {
      if (mounted) _toast(context, e);
    }
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: remote,
    builder: (context, _) {
      final w = remote.window(widget.window);
      final online = remote.link == TerminalLink.online;
      final gone = online && w == null;
      final screen = remote.screens[widget.window];
      final palette = remote.colors[widget.window] ?? TermColors.fallback;
      final text = SelectableText.rich(
        TextSpan(children: ansiSpans(screen ?? '', palette)),
        key: const ValueKey('screen'),
        style: _mono.copyWith(color: palette.foreground),
      );
      final note = _linkNote(remote);
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
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : ColoredBox(
                      color: palette.background,
                      child: SingleChildScrollView(
                        // The bottom of the screen is where things happen.
                        reverse: true,
                        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                        child: _wrap ? text : SingleChildScrollView(scrollDirection: Axis.horizontal, child: text),
                      ),
                    ),
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
                              hintText: w?.isOmp ?? false ? 'Prompt omp…' : 'Type a line…',
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
/// running omp unless turned off. Pops the new window's key.
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
    remote.attach();
  }

  @override
  void dispose() {
    remote.detach();
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
      final window = await remote.launch(cwd, omp: _omp);
      if (mounted) Navigator.of(context).pop(window);
    } on Object catch (e) {
      if (mounted) {
        setState(() => _launching = null);
        _toast(context, e);
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
      ].where((p) => words.every(_short(remote, p).toLowerCase().contains)).toList();
      final typed = _typed;
      final note = _linkNote(remote);
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
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
                          enabled: remote.link == TerminalLink.online,
                          onTap: () => unawaited(_launch(p)),
                          leading: Icon(
                            open.contains(p) ? Icons.terminal : Icons.folder_outlined,
                            size: 18,
                            color: C.dim2,
                          ),
                          title: Text(_short(remote, p), style: const TextStyle(fontSize: 14)),
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
