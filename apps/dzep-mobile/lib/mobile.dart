import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:dzep_core/account.dart' show Avatar;
import 'package:dzep_core/chat.dart';
import 'package:dzep_core/chat_images.dart';
import 'package:dzep_core/chat_view.dart';
import 'package:dzep_core/idea.dart';
import 'package:dzep_core/live_activity.dart';
import 'package:dzep_core/native.dart';
import 'package:dzep_core/remind.dart';
import 'package:dzep_core/session.dart';
import 'package:dzep_core/store.dart';
import 'package:dzep_core/terminal_remote.dart';
import 'package:dzep_core/ui.dart';
import 'package:dzep_mobile/chrome.dart';
import 'package:dzep_mobile/pocket.dart';
import 'package:dzep_mobile/setup_page.dart';
import 'package:dzep_mobile/terminal_view.dart';
import 'package:flutter/cupertino.dart' show CupertinoDatePicker;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The phone side of [Session]: registers a device token for the Todos
/// widget, keeps the
/// widget's todo snapshot current, and replays what those queued while
/// offline. All of it travels through what the native side shares with them
/// (ios/Shared/DzepShared.swift, android/…/DzepShared.kt).
class MobileSession extends Session {
  MobileSession(this._prefs, super.device);

  final SharedPreferences _prefs;

  /// A phone signs in only with a code from the Mac (functions/pair).
  @override
  bool get signsInWithGithub => false;

  static const _tokenKey = 'dzep_device_token';
  static const _tokenUserKey = 'dzep_device_token_user';

  static String _hash(String token) => sha256.convert(utf8.encode(token)).toString();

  static const _foldedKey = 'dzep_terminal_folded';

  /// The Terminal tab's projects (folders) showing only their heading.
  Set<String> get collapsedProjects => {...?_prefs.getStringList(_foldedKey)};

  Future<void> setCollapsedProjects(Set<String> cwds) => _prefs.setStringList(_foldedKey, [...cwds]);

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
      // The widget can't save directly until this works; retried on next launch.
      debugPrint('Džep: device token registration failed: $e');
    }
  }

  static const _pushTokenKey = 'dzep_push_token';
  static const _pushUserKey = 'dzep_push_user';

  /// Hands this phone's push token (APNs on iOS, FCM on Android) and push
  /// key to the user's server, which from then on pushes the reminders
  /// (functions/push). Until that has worked once for this user, reminders
  /// stay local; a server without the push function (not updated yet) keeps
  /// them local for good.
  Future<void> _registerPush(String userId) async {
    if (_prefs.getString(_pushUserKey) == userId) remindersByPush = true;
    try {
      final push = await Native.registerPush();
      if (push == null || user?.id != userId) return;
      await client.functions.invoke(
        'push',
        body: {'action': 'register', 'token': push.token, 'key': push.key, 'label': device, 'platform': pushPlatform},
      );
      await _prefs.setString(_pushTokenKey, push.token);
      await _prefs.setString(_pushUserKey, userId);
      remindersByPush = true;
    } on Object catch (e) {
      debugPrint('Džep: push registration failed: $e');
    }
  }

  /// Android: FCM handed over a new token (`pushToken`); the server needs it.
  Future<void> pushTokenChanged() async {
    final store = this.store;
    if (store != null) await _registerPush(store.userId);
  }

  @override
  Future<void> onSigningOut({required bool accountDeleted}) async {
    final token = _prefs.getString(_tokenKey);
    final pushToken = _prefs.getString(_pushTokenKey);
    final activities = await _forgetHere();
    // The followed sessions are this account's: the server stops updating
    // them too (iOS gives each its own token, which 'unregister' below
    // doesn't know).
    for (final a in activities) {
      if (a.token case final activityToken? when !accountDeleted) {
        await _tryServer(
          'activity end',
          () => client.functions.invoke(
            'push',
            body: {'action': 'activity_end', 'token': activityToken, 'session': a.key},
          ),
        );
      }
    }
    // A deleted account took its tokens with it.
    if (accountDeleted) return;
    if (token != null) {
      await _tryServer('device token', () => client.from('device_tokens').delete().eq('token_hash', _hash(token)));
    }
    if (pushToken != null) {
      await _tryServer(
        'push unregister',
        () => client.functions.invoke('push', body: {'action': 'unregister', 'token': pushToken}),
      );
    }
  }

  /// However the account went, also without [signOut] here (the server
  /// refused a refresh, the account was deleted on another device, the
  /// reviewer access ended): its widget token and followed sessions leave
  /// this phone.
  @override
  Future<void> onSignedOut() async {
    await _forgetHere();
  }

  /// Drops what this phone keeps for the account: the widget's device token
  /// (which also empties the widgets), the push registration's record, and
  /// the followed sessions, ended at once. Returns those sessions.
  Future<List<({String key, String? token})>> _forgetHere() async {
    await _prefs.remove(_tokenKey);
    await _prefs.remove(_tokenUserKey);
    await _prefs.remove(_pushTokenKey);
    await _prefs.remove(_pushUserKey);
    remindersByPush = false;
    await Native.setSharedToken(null);
    final activities = await Native.liveActivities();
    for (final a in activities) {
      await Native.endActivity(a.key, immediate: true);
    }
    return activities;
  }

  /// One server call of the sign-out; a failed one (offline) doesn't stop
  /// the rest.
  Future<void> _tryServer(String what, Future<Object?> Function() call) async {
    try {
      await call();
    } on Object catch (e) {
      debugPrint('Džep: $what at sign-out failed: $e');
    }
  }
}

/// A toast saying [text] with Undo. Flutter keeps a SnackBar with an action
/// up until it's dismissed unless told otherwise; this one goes on its own,
/// like the Mac's.
SnackBar undoSnackBar(String text, VoidCallback undo) => SnackBar(
  content: Text(text),
  persist: false,
  action: SnackBarAction(label: 'Undo', onPressed: undo),
);

class MobileApp extends StatelessWidget {
  const MobileApp({required this.session, @visibleForTesting this.terminal, super.key});
  final MobileSession session;

  /// See [HomePage.terminal].
  final TerminalRemote? terminal;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Džep',
    debugShowCheckedModeBanner: false,
    theme: appTheme().copyWith(
      scaffoldBackgroundColor: screenColor,
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Color(0xFF1F2A22),
        contentTextStyle: TextStyle(color: Color(0xFFBBF7D0)),
        actionTextColor: Colors.white,
      ),
    ),
    // No session, no app: only the Mac's code gets a phone in.
    home: ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final store = session.store;
        if (store == null) {
          return Scaffold(
            body: SafeArea(child: SetupPage(session: session)),
          );
        }
        return HomePage(session: session, store: store, terminal: terminal);
      },
    ),
  );
}

// ==================================================================== home

/// The home page's tabs, left to right: Terminal in the middle, and first.
enum HomeTab { pocket, terminal, ask }

class HomePage extends StatefulWidget {
  const HomePage({required this.session, required this.store, @visibleForTesting this.terminal, super.key});
  final MobileSession session;
  final IdeaStore store;

  /// A remote fed by hand (tests, screenshots); otherwise the home page
  /// joins the Mac over the session's server.
  final TerminalRemote? terminal;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  HomeTab _tab = HomeTab.terminal;
  PocketShow _show = PocketShow.all;
  final _pocket = GlobalKey<PocketViewState>();
  StreamSubscription<Uri>? _links;

  IdeaStore get store => widget.store;

  /// Open whenever the idea store is (see Session).
  ChatStore get chats => widget.session.chats!;

  /// The Mac's coding sessions and terminal windows, through Džep on the Mac; live
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
    if (t == null || attach == _terminalAttached || widget.terminal != null) return;
    _terminalAttached = attach;
    attach ? t.attach() : t.detach();
  }

  /// The Terminal tab, on coding session [key] (from a tapped push or Live
  /// Activity).
  void _openSession(String key) {
    setState(() => _tab = HomeTab.terminal);
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
    // followed session (Live Activity, Android's ongoing notification)
    // dzep://session?key=…. The stream also carries the link
    // that cold-started the app, so getInitialLink() would handle it twice.
    _links = AppLinks().uriLinkStream.listen(_onLink);
    Native.listen(_onNative);
    // A reminder or terminal push tap that launched the app.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_openTapped());
      unawaited(_openTappedSession());
    });
    if (widget.terminal case final t?) {
      _terminal = t;
    } else {
      unawaited(_startTerminal());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_links?.cancel());
    if (widget.terminal == null) {
      _terminal?.activities?.dispose();
      _terminal?.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _attachTerminal(attach: true);
        unawaited(widget.session.drainPending());
        unawaited(store.syncNow());
        // An AI connected from the Mac meanwhile shows up.
        unawaited(chats.checkAi());
        unawaited(_openTapped());
        unawaited(_openTappedSession());
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _attachTerminal(attach: false);
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  /// From the native side (ios/Runner/AppDelegate.swift, android/…/
  /// MainActivity.kt): a reminder was tapped, or its Done couldn't reach the
  /// server and waits to be replayed, or a terminal push was tapped, or a
  /// followed session has news, or (Android) FCM changed this phone's token.
  void _onNative(String event, Map<Object?, Object?> args) {
    if (!mounted) return;
    switch (event) {
      case 'openTodo':
        unawaited(_openTapped());
      case 'openTerminal':
        setState(() => _tab = HomeTab.terminal);
        // The session comes through takeTappedSession, once, whichever of
        // this and the resume asks first.
        unawaited(_openTappedSession());
      case 'pending':
        unawaited(widget.session.drainPending());
      case 'activityToken' || 'activityEnded':
        _terminal?.activities?.onNative(event, args);
      case 'pushToken':
        unawaited(widget.session.pushTokenChanged());
    }
  }

  /// Opens the todo whose reminder was tapped, if one was.
  Future<void> _openTapped() async {
    final id = await Native.takeTappedTodo();
    if (!mounted) return;
    final todo = id == null ? null : store.byId(id);
    if (todo == null) return;
    _showPocket(PocketShow.todos);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(idea: todo, store: store),
      ),
    );
  }

  void _showPocket(PocketShow show) => setState(() {
    _tab = HomeTab.pocket;
    _show = show;
  });

  void _onLink(Uri? uri) {
    if (uri == null || uri.scheme != 'dzep' || !mounted) return;
    if (uri.host == 'todos') {
      _showPocket(PocketShow.todos);
    } else if (uri.host == 'session') {
      final key = uri.queryParameters['key'];
      if (key != null && key.isNotEmpty) _openSession(key);
    } else if (uri.host == 'add') {
      final kind = Kind.parse(uri.queryParameters['kind']);
      _showPocket(switch (kind) {
        Kind.todo => PocketShow.todos,
        Kind.idea => PocketShow.ideas,
        Kind.note => PocketShow.notes,
      });
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
      backgroundColor: isIos ? S.cell : M.containerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) =>
          AddSheet(store: store, kind: kind, defaultProject: _pocket.currentState?.project ?? '', onNote: _openNote),
    );
    _addOpen = false;
  }

  /// The + of each tab: what it makes, and how.
  ({String tooltip, IconData icon, VoidCallback? onPressed}) get _add => switch (_tab) {
    HomeTab.terminal => (
      tooltip: 'New session',
      icon: Icons.add,
      onPressed: _terminal == null ? null : () => unawaited(openNewSession(context, _terminal!)),
    ),
    HomeTab.ask => (tooltip: 'New chat', icon: Icons.edit_outlined, onPressed: () => _openChat(null)),
    HomeTab.pocket => switch (_show) {
      PocketShow.notes => (tooltip: 'New note', icon: Icons.edit_outlined, onPressed: () => _openNote(null)),
      PocketShow.ideas => (tooltip: 'New idea', icon: Icons.add, onPressed: () => unawaited(_openAdd(Kind.idea))),
      PocketShow.todos => (tooltip: 'New todo', icon: Icons.add, onPressed: () => unawaited(_openAdd(Kind.todo))),
      PocketShow.all => (tooltip: 'New', icon: Icons.add, onPressed: () => unawaited(_openAdd(Kind.todo))),
    },
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, chats]),
    builder: (context, _) {
      final add = _add;
      return Scaffold(
        backgroundColor: screenColor,
        floatingActionButton: AddButton(tooltip: add.tooltip, icon: add.icon, onPressed: add.onPressed),
        bottomNavigationBar: AppTabBar(
          index: _tab.index,
          onSelect: (i) => setState(() => _tab = HomeTab.values[i]),
          tabs: [
            (
              icon: isIos ? Icons.inventory_2_outlined : Icons.inbox_outlined,
              selectedIcon: isIos ? Icons.inventory_2_rounded : Icons.inbox,
              label: 'Pocket',
              badge: store.openTodos.length,
            ),
            (icon: Icons.terminal_rounded, selectedIcon: Icons.terminal_rounded, label: 'Terminal', badge: 0),
            (icon: Icons.auto_awesome_outlined, selectedIcon: Icons.auto_awesome, label: 'Ask', badge: 0),
          ],
        ),
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageTitle(
                switch (_tab) {
                  HomeTab.pocket => 'Pocket',
                  HomeTab.terminal => 'Terminal',
                  HomeTab.ask => 'Ask',
                },
                trailing: [
                  SyncDot(store.syncState),
                  IconButton(
                    tooltip: 'Account',
                    onPressed: () => unawaited(_openAccount()),
                    icon: Avatar(url: widget.session.avatarUrl, name: widget.session.userName, size: 30),
                  ),
                ],
              ),
              Expanded(
                child: switch (_tab) {
                  HomeTab.pocket => PocketView(
                    key: _pocket,
                    store: store,
                    show: _show,
                    onShow: (s) => setState(() => _show = s),
                  ),
                  HomeTab.terminal => switch (_terminal) {
                    final t? => TerminalList(
                      remote: t,
                      folded: widget.session.collapsedProjects,
                      onFolded: (f) => unawaited(widget.session.setCollapsedProjects(f)),
                    ),
                    null => const Center(
                      child: Text('Reaching your Mac…', style: TextStyle(color: C.dim)),
                    ),
                  },
                  HomeTab.ask => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (chats.aiMissing)
                        const Padding(padding: EdgeInsets.fromLTRB(20, 8, 20, 8), child: NoAiNotice()),
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: () => Future.wait([chats.syncNow(), chats.checkAi()]),
                          child: _chatsList(),
                        ),
                      ),
                    ],
                  ),
                },
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _chatsList() {
    final list = chats.conversations;
    if (list.isEmpty) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(40),
            child: Text(
              chats.aiMissing ? 'No chats yet.' : 'No chats yet. Tap ✎ to ask a quick question.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: C.dim, height: 1.5),
            ),
          ),
        ],
      );
    }
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: AppTabBar.contentInset),
      children: [
        Panel(
          children: [
            for (final c in list)
              Dismissible(
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
                  title: Text(
                    c.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15),
                  ),
                  subtitle: Text(
                    (c.lastAnswer ?? '').replaceAll('\n', ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: C.dim),
                  ),
                  trailing: Text(stamp(c.updatedAt), style: const TextStyle(fontSize: 11, color: C.dim)),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _openAccount() => showModalBottomSheet<void>(
    context: context,
    backgroundColor: isIos ? S.cell : M.containerHigh,
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
                      Text(
                        '${store.ideas.length} ideas · signed in with your Mac\u2019s code',
                        style: const TextStyle(color: C.dim),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Text('Capture without opening the app', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text(
              '• Widgets: “Todos” ticks todos off from the home screen; “New idea” opens the add field.',
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
  const AddSheet({
    required this.store,
    required this.kind,
    required this.defaultProject,
    required this.onNote,
    super.key,
  });
  final IdeaStore store;
  final Kind kind;
  final String defaultProject;

  /// Note picked: the full-screen editor takes over, on what was typed so far (null: nothing yet).
  final void Function(Idea? note) onNote;

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
    // Todos take a `!` reminder (packages/dzep_core/lib/remind.dart), ideas a `@project`.
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
                ButtonSegment(value: Kind.note, label: Text('Note'), icon: Icon(Icons.sticky_note_2_outlined)),
              ],
              selected: {_kind},
              showSelectedIcon: false,
              onSelectionChanged: (s) {
                if (s.first != Kind.note) return setState(() => _kind = s.first);
                // A note is written full screen.
                final text = [_title.text.trim(), _notes.text.trim()].where((t) => t.isNotEmpty).join('\n');
                Navigator.of(context).pop();
                widget.onNote(text.isEmpty ? null : widget.store.addNote(text));
              },
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
      onPressed: () => unawaited(pickReminder(context, widget.store, idea)),
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
            ScaffoldMessenger.of(context).showSnackBar(undoSnackBar('Idea deleted', () => widget.store.restore(idea)));
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
Future<void> pickReminder(BuildContext context, IdeaStore store, Idea todo) async {
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
                  // The notice below says it all.
                  ? chats.aiMissing
                        ? const SizedBox.shrink()
                        : const Center(
                            child: Text('Ask a quick question below.', style: TextStyle(color: C.dim)),
                          )
                  : ChatTranscript(chat: chats, conversation: c, padding: const EdgeInsets.fromLTRB(18, 8, 18, 16)),
            ),
            if (chats.aiMissing)
              Container(
                decoration: const BoxDecoration(
                  color: C.bar,
                  border: Border(top: BorderSide(color: C.line)),
                ),
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                child: const SafeArea(top: false, child: NoAiNotice()),
              )
            else
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
                  ..showSnackBar(undoSnackBar('Note deleted', () => store.restore(note)));
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
