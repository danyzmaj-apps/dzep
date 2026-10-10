import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:dzep/chat.dart';
import 'package:dzep/chat_images.dart';
import 'package:dzep/chat_view.dart';
import 'package:dzep/idea.dart';
import 'package:dzep/live_activity.dart';
import 'package:dzep/main_window.dart' show Avatar, SignInPage;
import 'package:dzep/native.dart';
import 'package:dzep/popup.dart' show parseTitle;
import 'package:dzep/remind.dart';
import 'package:dzep/session.dart';
import 'package:dzep/setup.dart';
import 'package:dzep/store.dart';
import 'package:dzep/terminal_remote.dart';
import 'package:dzep/terminal_view.dart';
import 'package:dzep/ui.dart';
import 'package:flutter/cupertino.dart' show CupertinoDatePicker;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The iPhone side of [Session]: registers a device token for the Siri /
/// Action Button intents and the Todos widget, keeps the widget's todo
/// snapshot current, and replays what those queued while offline. All of it
/// travels through the App Group (ios/Shared/DzepShared.swift).
class MobileSession extends Session {
  MobileSession(this._prefs, super.device);

  final SharedPreferences _prefs;

  static const _tokenKey = 'dzep_device_token';
  static const _tokenUserKey = 'dzep_device_token_user';

  static String _hash(String token) => sha256.convert(utf8.encode(token)).toString();

  @override
  Future<void> onSignedIn(IdeaStore store) async {
    void shareTodos() {
      if (this.store != store) return;
      unawaited(
        Native.setSharedTodos([
          for (final t in store.openTodos) {'id': t.id, 'title': t.title},
        ]),
      );
    }

    store.addListener(shareTodos);
    shareTodos();
    unawaited(_registerPush(store.userId));
    await drainPending();
    final saved = _prefs.getString(_tokenKey);
    if (saved != null && _prefs.getString(_tokenUserKey) == store.userId) {
      await Native.setSharedToken(saved);
      return;
    }
    final token = List.generate(32, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    try {
      await client.from('device_tokens').insert({'token_hash': _hash(token), 'label': device});
      await _prefs.setString(_tokenKey, token);
      await _prefs.setString(_tokenUserKey, store.userId);
      await Native.setSharedToken(token);
    } on Object catch (e) {
      // Siri and the widget can't save directly until this works; retried on next launch.
      debugPrint('Džep: device token registration failed: $e');
    }
  }

  static const _pushTokenKey = 'dzep_push_token';
  static const _pushUserKey = 'dzep_push_user';

  /// Hands this iPhone's APNs token and push key to the user's server, which
  /// from then on pushes the reminders (functions/push). Until that has
  /// worked once for this user, reminders stay local; a server without the
  /// push function (not updated yet) keeps them local for good.
  Future<void> _registerPush(String userId) async {
    if (_prefs.getString(_pushUserKey) == userId) remindersByPush = true;
    try {
      final push = await Native.registerPush();
      if (push == null || user?.id != userId) return;
      await client.functions.invoke(
        'push',
        body: {'action': 'register', 'token': push.token, 'key': push.key, 'label': device},
      );
      await _prefs.setString(_pushTokenKey, push.token);
      await _prefs.setString(_pushUserKey, userId);
      remindersByPush = true;
    } on Object catch (e) {
      debugPrint('Džep: push registration failed: $e');
    }
  }

  @override
  Future<void> onSigningOut() async {
    final token = _prefs.getString(_tokenKey);
    final pushToken = _prefs.getString(_pushTokenKey);
    await _prefs.remove(_tokenKey);
    await _prefs.remove(_tokenUserKey);
    await _prefs.remove(_pushTokenKey);
    await _prefs.remove(_pushUserKey);
    remindersByPush = false;
    await Native.setSharedToken(null);
    if (token != null) await client.from('device_tokens').delete().eq('token_hash', _hash(token));
    if (pushToken != null) {
      await client.functions.invoke('push', body: {'action': 'unregister', 'token': pushToken});
    }
  }
}

class MobileApp extends StatelessWidget {
  const MobileApp({required this.session, super.key});
  final MobileSession session;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Džep',
    debugShowCheckedModeBanner: false,
    theme: appTheme().copyWith(
      scaffoldBackgroundColor: C.win,
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Color(0xFF1F2A22),
        contentTextStyle: TextStyle(color: Color(0xFFBBF7D0)),
        actionTextColor: Colors.white,
      ),
    ),
    home: ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final store = session.store;
        if (store == null) {
          return Scaffold(
            body: SafeArea(
              child: session.backend == null ? SetupPage(session: session) : SignInPage(session: session),
            ),
          );
        }
        return HomePage(session: session, store: store);
      },
    ),
  );
}

/// For fields' `onTapOutside`: a tap anywhere else puts the keyboard away.
/// (A tap on the field itself never counts, unlike a screen-wide tap
/// catcher, which can steal the tap that should focus it.)
void dismissKeyboard(PointerDownEvent _) => FocusManager.instance.primaryFocus?.unfocus();

// ==================================================================== home

typedef _Filter = ({bool project, String id});

class HomePage extends StatefulWidget {
  const HomePage({required this.session, required this.store, super.key});
  final MobileSession session;
  final IdeaStore store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  /// 0: Todos (the app opens here), 1: Ideas, 2: Notes, 3: Ask, 4: Terminal.
  int _tab = 0;
  bool _showDone = false;
  _Filter _filter = (project: false, id: 'all');
  String _query = '';
  final _search = TextEditingController();
  StreamSubscription<Uri>? _links;

  IdeaStore get store => widget.store;

  /// Open whenever the idea store is (see Session).
  ChatStore get chats => widget.session.chats!;

  /// The Mac's omp sessions and kitty windows, through Džep on the Mac; live
  /// while the app is in front. Null until its cache folder is known.
  TerminalRemote? _terminal;
  bool _terminalAttached = false;

  /// A tapped terminal push's session, waiting for [_terminal].
  String? _sessionToOpen;

  void _openChat(Conversation? c) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ChatPage(chats: chats, conversation: c),
    ),
  );

  /// An existing note, or a new one (null), in the full-screen editor.
  void _openNote(Idea? note) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => NotePage(store: store, note: note),
    ),
  );

  Future<void> _startTerminal() async {
    final dir = await getApplicationSupportDirectory();
    if (!mounted) return;
    final remote = TerminalRemote(widget.session.client, store.userId, Directory('${dir.path}/terminal'));
    remote.activities = LiveActivities(widget.session.client, remote);
    setState(() => _terminal = remote);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) _attachTerminal(attach: true);
    final key = _sessionToOpen;
    _sessionToOpen = null;
    if (key != null) _openSession(key);
  }

  void _attachTerminal({required bool attach}) {
    final t = _terminal;
    if (t == null || attach == _terminalAttached) return;
    _terminalAttached = attach;
    attach ? t.attach() : t.detach();
  }

  /// The Terminal tab, on omp session [key] (from a tapped push or Live
  /// Activity).
  void _openSession(String key) {
    setState(() => _tab = 4);
    final t = _terminal;
    if (t == null) {
      _sessionToOpen = key;
      return;
    }
    Navigator.of(context).popUntil((r) => r.isFirst);
    openSession(context, t, key);
  }

  /// Opens the session whose terminal push was tapped, if one was.
  Future<void> _openTappedSession() async {
    final key = await Native.takeTappedSession();
    if (key != null && mounted) _openSession(key);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The widgets open dzep://add, dzep://add?kind=todo and dzep://todos, a
    // Live Activity dzep://session?key=…. The stream also carries the link
    // that cold-started the app, so getInitialLink() would handle it twice.
    _links = AppLinks().uriLinkStream.listen(_onLink);
    Native.listen(_onNative);
    // A reminder or terminal push tap that launched the app.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_openTapped());
      unawaited(_openTappedSession());
    });
    unawaited(_startTerminal());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_links?.cancel());
    _search.dispose();
    _terminal?.activities?.dispose();
    _terminal?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _attachTerminal(attach: true);
        unawaited(widget.session.drainPending());
        unawaited(store.syncNow());
        unawaited(_openTapped());
        unawaited(_openTappedSession());
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _attachTerminal(attach: false);
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  /// From ios/Runner/AppDelegate.swift: a reminder was tapped, or its Done
  /// couldn't reach the server and waits in the App Group, or a terminal
  /// push was tapped, or a Live Activity has news.
  void _onNative(String event, Map<Object?, Object?> args) {
    if (!mounted) return;
    switch (event) {
      case 'openTodo':
        unawaited(_openTapped());
      case 'openTerminal':
        setState(() => _tab = 4);
        // The session comes through takeTappedSession, once, whichever of
        // this and the resume asks first.
        unawaited(_openTappedSession());
      case 'pending':
        unawaited(widget.session.drainPending());
      case 'activityToken' || 'activityEnded':
        _terminal?.activities?.onNative(event, args);
    }
  }

  /// Opens the todo whose reminder was tapped, if one was.
  Future<void> _openTapped() async {
    final id = await Native.takeTappedTodo();
    if (!mounted) return;
    final todo = id == null ? null : store.byId(id);
    if (todo == null) return;
    setState(() => _tab = 0);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(idea: todo, store: store),
      ),
    );
  }

  void _onLink(Uri? uri) {
    if (uri == null || uri.scheme != 'dzep' || !mounted) return;
    if (uri.host == 'todos') {
      setState(() => _tab = 0);
    } else if (uri.host == 'session') {
      final key = uri.queryParameters['key'];
      if (key != null && key.isNotEmpty) _openSession(key);
    } else if (uri.host == 'add') {
      final kind = Kind.parse(uri.queryParameters['kind']);
      setState(
        () => _tab = switch (kind) {
          Kind.todo => 0,
          Kind.idea => 1,
          Kind.note => 2,
        },
      );
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => kind == Kind.note ? _openNote(null) : unawaited(_openAdd(kind)),
      );
    }
  }

  bool _addOpen = false;

  Future<void> _openAdd(Kind kind) async {
    if (_addOpen) return;
    _addOpen = true;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.bar,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => AddSheet(store: store, kind: kind, defaultProject: _filter.project ? _filter.id : ''),
    );
    _addOpen = false;
  }

  bool _searchHit(Idea i) {
    final hay = '${i.title} ${i.notes} @${i.project}'.toLowerCase();
    return _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
  }

  void _toggleDone(Idea todo) {
    store.update(todo, done: !todo.done);
    unawaited(HapticFeedback.lightImpact());
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(todo.done ? 'Done ✓' : 'Reopened'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => store.update(todo, done: !todo.done),
          ),
        ),
      );
  }

  bool _matches(Idea i) {
    if (_filter.project && i.project != _filter.id) return false;
    return _searchHit(i);
  }

  void _delete(Idea i) {
    store.delete(i);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(switch (i.kind) {
            Kind.todo => 'Todo deleted',
            Kind.note => 'Note deleted',
            Kind.idea => 'Idea deleted',
          }),
          action: SnackBarAction(label: 'Undo', onPressed: () => store.restore(i)),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, chats]),
    builder: (context, _) => Scaffold(
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('add'),
        tooltip: switch (_tab) {
          0 => 'New todo',
          1 => 'New idea',
          2 => 'New note',
          3 => 'New chat',
          _ => 'New session',
        },
        backgroundColor: C.accent,
        foregroundColor: const Color(0xFF0E0F12),
        onPressed: () => switch (_tab) {
          2 => _openNote(null),
          3 => _openChat(null),
          4 => _terminal == null ? null : unawaited(openNewSession(context, _terminal!)),
          _ => unawaited(_openAdd(_tab == 0 ? Kind.todo : Kind.idea)),
        },
        child: Icon(_tab == 2 || _tab == 3 ? Icons.edit_outlined : Icons.add, size: 28),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        backgroundColor: C.bar,
        indicatorColor: C.sel,
        height: 64,
        onDestinationSelected: (t) => setState(() => _tab = t),
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: store.openTodos.isNotEmpty,
              label: Text('${store.openTodos.length}'),
              child: const Icon(Icons.check_circle_outline),
            ),
            label: 'Todos',
          ),
          const NavigationDestination(icon: Icon(Icons.lightbulb_outline), label: 'Ideas'),
          const NavigationDestination(icon: Icon(Icons.sticky_note_2_outlined), label: 'Notes'),
          const NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), label: 'Ask'),
          const NavigationDestination(icon: Icon(Icons.terminal), label: 'Terminal'),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
              child: Row(
                children: [
                  Text(switch (_tab) {
                    0 => 'Todos',
                    1 => 'Ideas',
                    2 => 'Notes',
                    3 => 'Ask',
                    _ => 'Terminal',
                  }, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  SyncDot(store.syncState),
                  IconButton(
                    tooltip: 'Account',
                    onPressed: () => unawaited(_openAccount()),
                    icon: Avatar(url: widget.session.avatarUrl, name: widget.session.userName, size: 28),
                  ),
                ],
              ),
            ),
            if (_tab < 3)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                child: TextField(
                  onTapOutside: dismissKeyboard,
                  controller: _search,
                  onChanged: (q) => setState(() => _query = q),
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    hintText: 'Search',
                    hintStyle: const TextStyle(color: C.dim2),
                    prefixIcon: const Icon(Icons.search, color: C.dim, size: 20),
                    filled: true,
                    fillColor: C.field,
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  ),
                ),
              ),
            if (_tab == 1) SizedBox(height: 38, child: _filters()),
            const Divider(height: 1, color: C.line),
            Expanded(
              child: switch (_tab) {
                4 => _terminal == null ? const SizedBox.shrink() : TerminalList(remote: _terminal!),
                3 => RefreshIndicator(onRefresh: chats.syncNow, child: _chatsList()),
                2 => RefreshIndicator(onRefresh: store.syncNow, child: _notesList()),
                _ => RefreshIndicator(onRefresh: store.syncNow, child: _tab == 0 ? _todosList() : _ideasList()),
              },
            ),
          ],
        ),
      ),
    ),
  );

  Widget _empty(String text) => ListView(
    children: [
      Padding(
        padding: const EdgeInsets.all(40),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: C.dim, height: 1.5),
        ),
      ),
    ],
  );

  Widget _chatsList() {
    final list = chats.conversations;
    if (list.isEmpty) return _empty('No chats yet. Tap ✎ to ask a quick question.');
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: list.length,
      separatorBuilder: (_, _) => const Divider(height: 1, color: C.line, indent: 52),
      itemBuilder: (context, i) {
        final c = list[i];
        return Dismissible(
          key: ValueKey('chat-${c.id}'),
          direction: DismissDirection.endToStart,
          background: Container(
            color: const Color(0xFF7F1D1D),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 24),
            child: const Icon(Icons.delete_outline, color: Colors.white),
          ),
          onDismissed: (_) {
            chats.delete(c);
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(content: Text('Chat deleted')));
          },
          child: ListTile(
            onTap: () => _openChat(c),
            leading: Icon(Icons.auto_awesome, size: 18, color: chats.streaming == c ? C.accent : C.dim2),
            title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
            subtitle: Text(
              (c.lastAnswer ?? '').replaceAll('\n', ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: C.dim),
            ),
            trailing: Text(stamp(c.updatedAt), style: const TextStyle(fontSize: 11, color: C.dim)),
          ),
        );
      },
    );
  }

  Widget _ideasList() {
    final ideas = store.ideas.where(_matches).toList();
    if (ideas.isEmpty) {
      return _empty(
        _query.isNotEmpty
            ? 'No matches.'
            : !_filter.project
            ? 'No ideas yet.\nTap + or say “Hey Siri, add an idea to Džep”.'
            : 'Nothing here yet.',
      );
    }
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      // Room to scroll the last rows clear of the + button and a snackbar.
      padding: const EdgeInsets.only(bottom: 170),
      itemCount: ideas.length,
      itemBuilder: (context, k) => _row(ideas[k]),
    );
  }

  Widget _notesList() {
    final notes = store.notes.where(_searchHit).toList();
    if (notes.isEmpty) {
      return _empty(_query.isNotEmpty ? 'No matches.' : 'No notes yet.\nTap ✎ or say “Hey Siri, add a note to Džep”.');
    }
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: 170),
      itemCount: notes.length,
      itemBuilder: (context, k) {
        final n = notes[k];
        final preview = n.notes.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).skip(1).firstOrNull;
        return Dismissible(
          key: ValueKey(n.id),
          direction: DismissDirection.endToStart,
          background: Container(
            color: const Color(0xFF7F1D1D),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 24),
            child: const Icon(Icons.delete_outline, color: Colors.white),
          ),
          onDismissed: (_) => _delete(n),
          child: InkWell(
            onTap: () => _openNote(n),
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFF1D1F25))),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          highlight(
                            n.title.isEmpty ? 'Empty note' : n.title,
                            _query,
                            const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: C.text),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (preview != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              preview,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, color: C.dim, height: 1.35),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(stamp(n.updatedAt), style: const TextStyle(fontSize: 12, color: C.dim2)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _todosList() {
    final open = store.openTodos.where(_searchHit).toList();
    final done = store.doneTodos.where(_searchHit).toList();
    if (open.isEmpty && done.isEmpty) {
      return _empty(_query.isNotEmpty ? 'No matches.' : 'All done 🎉\nTap + or say “Hey Siri, add a todo to Džep”.');
    }
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: 170),
      children: [
        if (open.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'All done 🎉',
              textAlign: TextAlign.center,
              style: TextStyle(color: C.dim),
            ),
          ),
        for (final t in open) _todoRow(t),
        if (done.isNotEmpty)
          InkWell(
            onTap: () => setState(() => _showDone = !_showDone),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Text('DONE · ${done.length}', style: const TextStyle(fontSize: 12, letterSpacing: .6, color: C.dim)),
                  const Spacer(),
                  Icon(_showDone ? Icons.expand_less : Icons.expand_more, color: C.dim, size: 20),
                ],
              ),
            ),
          ),
        if (_showDone)
          for (final t in done) _todoRow(t),
      ],
    );
  }

  Widget _todoRow(Idea t) => Dismissible(
    key: ValueKey('todo-${t.id}-${t.done}'),
    background: Container(
      color: const Color(0xFF14532D),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 24),
      child: Icon(t.done ? Icons.undo : Icons.check, color: Colors.white),
    ),
    secondaryBackground: Container(
      color: const Color(0xFF7F1D1D),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 24),
      child: const Icon(Icons.delete_outline, color: Colors.white),
    ),
    onDismissed: (dir) => dir == DismissDirection.startToEnd ? _toggleDone(t) : _delete(t),
    child: InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DetailPage(idea: t, store: store),
        ),
      ),
      onLongPress: t.done ? null : () => unawaited(_pickReminder(context, store, t)),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 20, 4),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF1D1F25))),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: t.done ? 'Reopen' : 'Done',
              onPressed: () => _toggleDone(t),
              icon: TodoCheck(done: t.done, size: 22),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      color: t.done ? C.dim : C.text,
                      decoration: t.done ? TextDecoration.lineThrough : null,
                      decorationColor: C.dim,
                    ),
                  ),
                  if (t.remindAt case final at? when !t.done)
                    Padding(padding: const EdgeInsets.only(top: 3), child: ReminderChip(at)),
                ],
              ),
            ),
            Text(stamp(t.createdAt), style: const TextStyle(fontSize: 12, color: C.dim2)),
          ],
        ),
      ),
    ),
  );

  Widget _filters() {
    Widget chip(_Filter f, String label, {Color? dot}) {
      final on = _filter == f;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          selected: on,
          showCheckmark: false,
          onSelected: (_) => setState(() => _filter = f),
          backgroundColor: C.field,
          selectedColor: C.sel,
          side: BorderSide(color: on ? C.accent : C.line2),
          avatar: dot == null ? null : Dot(dot),
          label: Text(label, style: TextStyle(fontSize: 13, color: on ? C.text : C.dim)),
          visualDensity: VisualDensity.compact,
        ),
      );
    }

    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        chip((project: false, id: 'all'), 'All'),
        for (final p in store.projects) chip((project: true, id: p), '@$p'),
      ],
    );
  }

  Widget _row(Idea i) {
    final firstNote = i.notes.split('\n').first;
    return Dismissible(
      key: ValueKey(i.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: const Color(0xFF7F1D1D),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      onDismissed: (_) => _delete(i),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DetailPage(idea: i, store: store),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFF1D1F25))),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(padding: EdgeInsets.only(top: 6), child: Dot(C.dim)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      highlight(
                        i.title.isEmpty ? 'Untitled' : i.title,
                        _query,
                        const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: C.text),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (firstNote.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          firstNote,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, color: C.dim),
                        ),
                      ),
                    if (i.project.isNotEmpty)
                      Padding(padding: const EdgeInsets.only(top: 6), child: ProjectChip(i.project)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(stamp(i.createdAt), style: const TextStyle(fontSize: 12, color: C.dim2)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAccount() => showModalBottomSheet<void>(
    context: context,
    backgroundColor: C.bar,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Avatar(url: widget.session.avatarUrl, name: widget.session.userName, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.session.userName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      Text('${store.ideas.length} ideas · signed in with GitHub', style: const TextStyle(color: C.dim)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Text('Capture without opening the app', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text(
              '• Say “Hey Siri, add a todo to Džep” (or “an idea”).\n'
              '• Action Button: Settings → Action Button → Shortcut → Džep → Add Todo.\n'
              '• Widgets: “Todos” ticks todos off from the Home Screen; “New idea” opens the add field.',
              style: TextStyle(color: C.dim, height: 1.6),
            ),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: () {
                Navigator.of(sheet).pop();
                unawaited(widget.session.signOut());
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFCA5A5),
                side: const BorderSide(color: C.line2),
              ),
              child: const Text('Sign out'),
            ),
            TextButton(
              onPressed: () async {
                if (!await confirmDeleteAccount(sheet)) return;
                if (sheet.mounted) Navigator.of(sheet).pop();
                try {
                  await widget.session.deleteAccount();
                } on Object catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Account not deleted: $e')));
                  }
                }
              },
              style: TextButton.styleFrom(foregroundColor: C.dim2),
              child: const Text('Delete account…'),
            ),
          ],
        ),
      ),
    ),
  );
}

// ==================================================================== add

class AddSheet extends StatefulWidget {
  const AddSheet({required this.store, required this.kind, required this.defaultProject, super.key});
  final IdeaStore store;
  final Kind kind;
  final String defaultProject;

  @override
  State<AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<AddSheet> {
  final _title = TextEditingController();
  final _notes = TextEditingController();
  late String _project = widget.defaultProject;
  late Kind _kind = widget.kind;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    final todo = _kind == Kind.todo;
    // Todos take a `!` reminder (lib/remind.dart), ideas a `@project`.
    final remind = todo ? parseReminder(_title.text, DateTime.now()) : null;
    final parsed = remind != null ? (title: remind.title, project: '') : parseTitle(_title.text);
    if (parsed.title.isEmpty) return;
    widget.store.add(
      title: parsed.title,
      kind: _kind,
      notes: _notes.text,
      project: parsed.project.isNotEmpty ? parsed.project : _project,
      remindAt: remind?.at,
    );
    unawaited(HapticFeedback.lightImpact());
    Navigator.of(context).pop();
    final at = remind?.at;
    final saved = todo ? 'Todo added ✓' : 'Idea saved ✓';
    final message = at == null ? saved : '$saved  🔔 ${reminderLabel(at, DateTime.now())}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<Kind>(
              key: const ValueKey('add-kind'),
              segments: const [
                ButtonSegment(value: Kind.todo, label: Text('Todo'), icon: Icon(Icons.check_circle_outline)),
                ButtonSegment(value: Kind.idea, label: Text('Idea'), icon: Icon(Icons.lightbulb_outline)),
              ],
              selected: {_kind},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            const SizedBox(height: 14),
            TextField(
              onTapOutside: dismissKeyboard,
              key: const ValueKey('add-title'),
              controller: _title,
              autofocus: true,
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 19, height: 1.35),
              decoration: plainInput.copyWith(
                hintText: _kind == Kind.todo ? 'Add a todo…  !15:00' : 'Drop an idea…',
                hintStyle: const TextStyle(color: C.dim2),
              ),
              onSubmitted: (_) => _save(),
            ),
            // What a `!` token will set, as it's typed.
            if (_kind == Kind.todo)
              ListenableBuilder(
                listenable: _title,
                builder: (context, _) => switch (parseReminder(_title.text, DateTime.now()).at) {
                  final at? => Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(alignment: Alignment.centerLeft, child: ReminderChip(at)),
                  ),
                  null => const SizedBox.shrink(),
                },
              ),
            const SizedBox(height: 12),
            TextField(
              onTapOutside: dismissKeyboard,
              key: const ValueKey('add-notes'),
              controller: _notes,
              minLines: 2,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 15, height: 1.5, color: Color(0xFFC9CCD5)),
              decoration: plainInput.copyWith(
                hintText: 'Description (optional)',
                hintStyle: const TextStyle(color: C.dim2),
              ),
            ),
            if (_kind == Kind.idea && widget.store.projects.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final p in widget.store.projects)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          selected: _project == p,
                          showCheckmark: false,
                          onSelected: (on) => setState(() => _project = on ? p : ''),
                          backgroundColor: C.field,
                          selectedColor: C.projectBg,
                          side: BorderSide(color: _project == p ? C.projectFg : C.line2),
                          label: Text(
                            '@$p',
                            style: TextStyle(fontSize: 12, color: _project == p ? C.projectFg : C.dim),
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            ListenableBuilder(
              listenable: _title,
              builder: (context, _) => FilledButton(
                key: const ValueKey('add-save'),
                onPressed: _title.text.trim().isEmpty ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: C.accent,
                  foregroundColor: const Color(0xFF0E0F12),
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ==================================================================== detail

class DetailPage extends StatefulWidget {
  const DetailPage({required this.idea, required this.store, super.key});
  final Idea idea;
  final IdeaStore store;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late final _title = TextEditingController(text: widget.idea.title);
  late final _notes = TextEditingController(text: widget.idea.notes);
  late final _project = TextEditingController(text: widget.idea.project);

  Idea get idea => widget.idea;

  @override
  void dispose() {
    final p = _project.text.trim().replaceFirst(RegExp('^@'), '');
    if (p != idea.project) widget.store.update(idea, project: p);
    _title.dispose();
    _notes.dispose();
    _project.dispose();
    super.dispose();
  }

  /// Tap to set or change the todo's reminder, × to clear it.
  Widget _remindChip() {
    final at = idea.remindAt;
    final color = at == null ? C.dim : (at.isAfter(DateTime.now()) ? C.accent : C.warn);
    return InputChip(
      onPressed: () => unawaited(_pickReminder(context, widget.store, idea)),
      onDeleted: at == null ? null : () => widget.store.update(idea, remind: (at: null)),
      deleteIconColor: C.dim,
      backgroundColor: C.field,
      side: BorderSide(color: at == null ? C.line2 : color),
      avatar: Icon(Icons.notifications_none, size: 18, color: color),
      label: Text(
        at == null ? 'Remind me' : reminderLabel(at, DateTime.now()),
        style: TextStyle(color: at == null ? C.dim : C.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: C.win,
      surfaceTintColor: Colors.transparent,
      actions: [
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline, color: C.dim),
          onPressed: () {
            widget.store.delete(idea);
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Idea deleted'),
                action: SnackBarAction(label: 'Undo', onPressed: () => widget.store.restore(idea)),
              ),
            );
          },
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
        children: [
          TextField(
            onTapOutside: dismissKeyboard,
            controller: _title,
            maxLines: null,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            decoration: plainInput.copyWith(
              hintText: idea.isTodo ? 'Untitled todo' : 'Untitled idea',
              hintStyle: const TextStyle(color: C.dim2),
            ),
            onChanged: (t) => widget.store.update(idea, title: t),
          ),
          const SizedBox(height: 18),
          if (idea.isTodo)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  selected: idea.done,
                  showCheckmark: false,
                  onSelected: (on) => widget.store.update(idea, done: on),
                  backgroundColor: C.field,
                  selectedColor: C.sel,
                  side: BorderSide(color: idea.done ? C.ok : C.line2),
                  avatar: TodoCheck(done: idea.done),
                  label: Text(idea.done ? 'Done' : 'Mark done', style: TextStyle(color: idea.done ? C.text : C.dim)),
                ),
                if (!idea.done) _remindChip(),
              ],
            )
          else ...[
            TextField(
              onTapOutside: dismissKeyboard,
              controller: _project,
              style: const TextStyle(fontSize: 14, color: C.projectFg),
              decoration: InputDecoration(
                prefixText: '@ ',
                prefixStyle: const TextStyle(color: C.dim),
                hintText: 'project',
                hintStyle: const TextStyle(color: C.dim2),
                filled: true,
                fillColor: C.field,
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
          ],
          const SizedBox(height: 20),
          TextField(
            onTapOutside: dismissKeyboard,
            controller: _notes,
            maxLines: null,
            minLines: 8,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 16, height: 1.6, color: Color(0xFFD7DAE2)),
            decoration: plainInput.copyWith(
              hintText: 'Description: context, links, how it could work…',
              hintStyle: const TextStyle(color: C.dim2),
            ),
            onChanged: (t) => widget.store.update(idea, notes: t),
          ),
          const SizedBox(height: 24),
          Text(
            'Added ${stamp(idea.createdAt)}${idea.device.isEmpty ? '' : ' on ${idea.device}'}',
            style: const TextStyle(fontSize: 12, color: C.dim2),
          ),
        ],
      ),
    ),
  );
}

// ==================================================================== remind

/// Sets a todo's reminder on a date-and-time wheel, or clears it.
Future<void> _pickReminder(BuildContext context, IdeaStore store, Idea todo) async {
  final picked = await showModalBottomSheet<({DateTime? at})>(
    context: context,
    backgroundColor: C.bar,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => _ReminderSheet(current: todo.remindAt),
  );
  if (picked != null) store.update(todo, remind: picked);
}

/// Pops `(at: time)` to set, `(at: null)` to clear.
class _ReminderSheet extends StatefulWidget {
  const _ReminderSheet({required this.current});
  final DateTime? current;

  @override
  State<_ReminderSheet> createState() => _ReminderSheetState();
}

class _ReminderSheetState extends State<_ReminderSheet> {
  final _now = DateTime.now();

  /// The wheel starts on the current reminder if it's still ahead, else on
  /// the next full hour.
  late DateTime _at = switch (widget.current?.toLocal()) {
    final at? when at.isAfter(_now) => at,
    _ => DateTime(_now.year, _now.month, _now.day, _now.hour + 1),
  };

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Remind me', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          SizedBox(
            height: 200,
            child: CupertinoDatePicker(
              initialDateTime: _at,
              minimumDate: _now,
              use24hFormat: MediaQuery.alwaysUse24HourFormatOf(context),
              onDateTimeChanged: (t) => _at = t,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (widget.current != null)
                TextButton(
                  onPressed: () => Navigator.of(context).pop((at: null)),
                  child: const Text('Clear', style: TextStyle(color: Color(0xFFFCA5A5))),
                ),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.of(context).pop((at: _at)),
                style: FilledButton.styleFrom(
                  backgroundColor: C.accent,
                  foregroundColor: const Color(0xFF0E0F12),
                  minimumSize: const Size(120, 46),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Set', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

// ==================================================================== ask

/// One quick-question chat (null: a new one), continued from the composer.
class ChatPage extends StatefulWidget {
  const ChatPage({required this.chats, required this.conversation, super.key});
  final ChatStore chats;
  final Conversation? conversation;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late Conversation? _c = widget.conversation;
  final _field = TextEditingController();
  final _focus = FocusNode();
  final _attachments = ChatAttachments();

  ChatStore get chats => widget.chats;

  @override
  void initState() {
    super.initState();
    _field.addListener(() => setState(() {}));
    _attachments.addListener(() => setState(() {}));
    if (_c == null) _focus.requestFocus();
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    _attachments.dispose();
    super.dispose();
  }

  void _send() {
    final text = _field.text;
    if ((text.trim().isEmpty && _attachments.isEmpty) || chats.busy) return;
    _field.clear();
    unawaited(chats.send(text, into: _c, images: _attachments.take()));
    // A new chat exists from here on.
    setState(() => _c = chats.current);
  }

  Future<void> _attach(String from) async {
    if (from == 'photos') return await _attachments.pick();
    if (!await _attachments.paste() && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('There is no image on the clipboard.')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: chats,
    builder: (context, _) {
      final c = _c;
      // Deleted on another device.
      if (c != null && chats.byId(c.id) == null && !chats.busy) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).maybePop();
        });
      }
      final canSend = (_field.text.trim().isNotEmpty || !_attachments.isEmpty) && !chats.busy;
      return Scaffold(
        appBar: AppBar(
          backgroundColor: C.win,
          title: Text(c?.title ?? 'New chat', maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (c != null)
              IconButton(
                tooltip: 'Copy last answer',
                onPressed: () => copyAnswer(context, c.lastAnswer),
                icon: const Icon(Icons.content_copy, size: 20),
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: c == null || c.messages.isEmpty
                  ? const Center(
                      child: Text('Ask a quick question below.', style: TextStyle(color: C.dim)),
                    )
                  : ChatTranscript(chat: chats, conversation: c, padding: const EdgeInsets.fromLTRB(18, 8, 18, 16)),
            ),
            Container(
              decoration: const BoxDecoration(
                color: C.bar,
                border: Border(top: BorderSide(color: C.line)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: SafeArea(
                top: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 8),
                      child: AttachmentStrip(attachments: _attachments),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        TextFieldTapRegion(
                          child: PopupMenuButton<String>(
                            tooltip: 'Attach images',
                            enabled: _attachments.room > 0,
                            icon: Icon(
                              Icons.add_photo_alternate_outlined,
                              color: _attachments.room > 0 ? C.dim : C.dim2,
                            ),
                            color: C.bar,
                            onSelected: (from) => unawaited(_attach(from)),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'paste', child: Text('Paste image')),
                              PopupMenuItem(value: 'photos', child: Text('Choose from Photos')),
                            ],
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            onTapOutside: dismissKeyboard,
                            controller: _field,
                            focusNode: _focus,
                            minLines: 1,
                            maxLines: 6,
                            textCapitalization: TextCapitalization.sentences,
                            style: const TextStyle(fontSize: 16, height: 1.4),
                            decoration: plainInput.copyWith(
                              hintText: c == null ? 'Ask a quick question…' : 'Follow up…',
                              hintStyle: const TextStyle(color: C.dim2),
                              contentPadding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                          ),
                        ),
                        // Part of the field for tap-outside: sending keeps the
                        // keyboard up for the next question.
                        TextFieldTapRegion(
                          child: IconButton(
                            tooltip: 'Send',
                            onPressed: canSend ? _send : null,
                            icon: chats.busy
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

// ==================================================================== notes

/// A note, full screen: one text, saved as it's typed (the first line is the
/// title). A new one ([note] null) exists once something is written.
class NotePage extends StatefulWidget {
  const NotePage({required this.store, required this.note, super.key});
  final IdeaStore store;
  final Idea? note;

  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage> {
  late Idea? _note = widget.note;
  late final _text = TextEditingController(text: widget.note?.notes ?? '');
  final _focus = FocusNode();

  IdeaStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    if (_note == null) _focus.requestFocus();
    store.addListener(_onStore);
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Edited on another device: show it unless it's being typed in here;
  /// deleted there: close.
  void _onStore() {
    final note = _note;
    if (note == null || !mounted) return;
    if (store.byId(note.id) == null) {
      Navigator.of(context).maybePop();
    } else if (!_focus.hasFocus && _text.text != note.notes) {
      _text.text = note.notes;
    }
  }

  void _changed(String text) {
    final note = _note;
    if (note != null) {
      store.editNote(note, text);
    } else if (text.trim().isNotEmpty) {
      setState(() => _note = store.addNote(text));
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.win,
        title: Text(note == null ? 'New note' : stamp(note.updatedAt), style: const TextStyle(fontSize: 15)),
        actions: [
          if (note != null) ...[
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.content_copy, size: 20),
              onPressed: () => copyAnswer(context, note.notes.trim()),
            ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                // This page closes itself; the listener would close it twice.
                store
                  ..removeListener(_onStore)
                  ..delete(note);
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(
                      content: const Text('Note deleted'),
                      action: SnackBarAction(label: 'Undo', onPressed: () => store.restore(note)),
                    ),
                  );
              },
            ),
          ],
        ],
      ),
      body: GestureDetector(
        // A tap below the text still lands in the editor.
        behavior: HitTestBehavior.translucent,
        onTap: _focus.requestFocus,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: TextField(
            key: const ValueKey('note-text'),
            controller: _text,
            focusNode: _focus,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 17, height: 1.5),
            decoration: plainInput.copyWith(
              hintText: 'Write anything. The first line is the title.',
              hintStyle: const TextStyle(color: C.dim2),
            ),
            onChanged: _changed,
          ),
        ),
      ),
    );
  }
}
