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
import 'package:dzep_core/tabs.dart';
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

  static const _tabsKey = 'dzep_tabs';

  /// Which tabs the bottom bar shows, in what order: this phone's own
  /// choice, kept across sign-outs.
  TabChoice<HomeTab> get tabs => TabChoice.parse(
    HomeTab.values,
    order: _prefs.getStringList('${_tabsKey}_order'),
    hidden: _prefs.getStringList('${_tabsKey}_hidden'),
  );

  Future<void> setTabs(TabChoice<HomeTab> tabs) async {
    await _prefs.setStringList('${_tabsKey}_order', tabs.orderNames);
    await _prefs.setStringList('${_tabsKey}_hidden', tabs.hiddenNames);
    notifyListeners();
  }

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
    theme: _theme(appTheme()),
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

  static ThemeData _theme(ThemeData base) => base.copyWith(
    scaffoldBackgroundColor: screenColor,
    // Rows show they were pressed: the iOS cell highlight, Android's ink.
    splashFactory: isIos ? NoSplash.splashFactory : InkSparkle.splashFactory,
    highlightColor: const Color(0x14FFFFFF),
    appBarTheme: AppBarTheme(
      backgroundColor: C.win,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      // The theme's own font (a bare style would drop its family).
      titleTextStyle: base.textTheme.titleMedium!.copyWith(fontSize: 17, fontWeight: FontWeight.w600, color: C.text),
      actionsIconTheme: const IconThemeData(color: C.dim, size: 22),
    ),
    // A button turning on goes all at once: animated, its fill flips at
    // once while its label takes 200ms to darken, unreadable meanwhile.
    filledButtonTheme: const FilledButtonThemeData(style: ButtonStyle(animationDuration: Duration.zero)),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Color(0xFF1F2A22),
      contentTextStyle: TextStyle(color: Color(0xFFBBF7D0)),
      actionTextColor: Colors.white,
    ),
  );
}

// ==================================================================== home

/// The home page's tabs, in the bar's standard order: Terminal in the
/// middle, and first. Each phone picks which show and their order
/// ([MobileSession.tabs]).
enum HomeTab {
  pocket('Pocket'),
  terminal('Terminal'),
  ask('Ask');

  const HomeTab(this.label);
  final String label;

  IconData get icon => switch (this) {
    pocket => isIos ? Icons.inventory_2_outlined : Icons.inbox_outlined,
    terminal => Icons.terminal_rounded,
    ask => Icons.auto_awesome_outlined,
  };

  IconData get selectedIcon => switch (this) {
    pocket => isIos ? Icons.inventory_2_rounded : Icons.inbox,
    terminal => Icons.terminal_rounded,
    ask => Icons.auto_awesome,
  };
}

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
  /// The tab on screen: Terminal at first, or the first one showing when
  /// Terminal doesn't (see [_visibleTabs]).
  HomeTab _tab = HomeTab.terminal;
  PocketShow _show = PocketShow.all;
  final _pocket = GlobalKey<PocketViewState>();

  /// The tabs' scroll views while off screen, kept off the Scaffold's
  /// primary controller: it takes one at a time, and a status-bar tap
  /// scrolls the tab on screen.
  final Map<HomeTab, ScrollController> _hiddenScroll = {for (final tab in HomeTab.values) tab: ScrollController()};
  StreamSubscription<Uri>? _links;

  IdeaStore get store => widget.store;

  /// Open whenever the idea store is (see Session).
  ChatStore get chats => widget.session.chats!;

  /// The tabs showing, in their order. The tab on screen moves to the
  /// first of them when its own isn't one (just switched off).
  List<HomeTab> _visibleTabs() {
    final visible = widget.session.tabs.visible;
    if (!visible.contains(_tab)) _tab = visible.first;
    return visible;
  }

  /// Puts [tab] on screen, unless it's switched off: then the tab stays,
  /// and what asked for it (a session, a todo) still opens on top.
  void _goTo(HomeTab tab) {
    if (widget.session.tabs.shows(tab)) setState(() => _tab = tab);
  }

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

  /// Coding session [key] (from a tapped push or Live Activity), over the
  /// Terminal tab when that shows.
  void _openSession(String key) {
    _goTo(HomeTab.terminal);
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
    for (final c in _hiddenScroll.values) {
      c.dispose();
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
        _goTo(HomeTab.terminal);
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
    if (widget.session.tabs.shows(HomeTab.pocket)) _tab = HomeTab.pocket;
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
    await showAppSheet<void>(
      context,
      isScrollControlled: true,
      // Pocket's project, or none when Pocket isn't built (switched off).
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
      final visible = _visibleTabs();
      final add = _add;
      // One tab needs no bar: the + and the lists sit at the home indicator.
      final bar = visible.length > 1;
      return Scaffold(
        backgroundColor: screenColor,
        floatingActionButton: AddButton(tooltip: add.tooltip, icon: add.icon, onPressed: add.onPressed),
        bottomNavigationBar: bar
            ? AppTabBar(
                index: visible.indexOf(_tab),
                onSelect: (i) => setState(() => _tab = visible[i]),
                tabs: [
                  for (final tab in visible)
                    (
                      icon: tab.icon,
                      selectedIcon: tab.selectedIcon,
                      label: tab.label,
                      badge: tab == HomeTab.pocket ? store.openTodos.length : 0,
                    ),
                ],
              )
            : null,
        body: SafeArea(
          // Without a bar, the lists end above the home indicator, so their
          // AppTabBar.contentInset still clears the +.
          bottom: !bar,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageTitle(
                _tab.label,
                trailing: [
                  SyncDot(store.syncState),
                  IconButton(
                    tooltip: 'Account',
                    onPressed: () => unawaited(_openAccount()),
                    icon: Avatar(url: widget.session.avatarUrl, name: widget.session.userName, size: 30),
                  ),
                ],
              ),
              // Every tab showing stays built, so search, filters and scroll
              // survive a trip to another tab (keyed: also a reorder). iOS
              // swaps tabs at once, as its own tab bars do; Material 3 fades
              // the one shown in.
              Expanded(
                child: Builder(
                  builder: (context) {
                    final primary = PrimaryScrollController.maybeOf(context);
                    return IndexedStack(
                      index: visible.indexOf(_tab),
                      children: [
                        for (final tab in visible)
                          PrimaryScrollController(
                            key: ValueKey(tab),
                            controller: tab == _tab && primary != null ? primary : _hiddenScroll[tab]!,
                            child: AnimatedOpacity(
                              opacity: tab == _tab ? 1 : 0,
                              duration: isIos ? Duration.zero : Motion.fast,
                              curve: Motion.ease,
                              child: _tabBody(tab),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _tabBody(HomeTab tab) => switch (tab) {
    HomeTab.pocket => PocketView(key: _pocket, store: store, show: _show, onShow: (s) => setState(() => _show = s)),
    HomeTab.terminal => switch (_terminal) {
      final t? => TerminalList(
        remote: t,
        // Only the tab on screen keeps the phone awake.
        active: _tab == HomeTab.terminal,
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
        if (chats.aiMissing) const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 8), child: NoAiNotice()),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => Future.wait([chats.syncNow(), chats.checkAi()]),
            child: _chatsList(),
          ),
        ),
      ],
    ),
  };

  Widget _chatsList() {
    final list = chats.conversations;
    if (list.isEmpty) {
      // Centred, yet still a scroll view so pull-to-refresh works.
      return LayoutBuilder(
        builder: (context, box) => ListView(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: Text(
                    chats.aiMissing ? 'No chats yet.' : 'No chats yet. Tap ✎ to ask a quick question.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: C.dim, height: 1.5),
                  ),
                ),
              ),
            ),
          ],
        ),
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
                    ..showSnackBar(undoSnackBar('Chat deleted', () => unawaited(chats.restore(c))));
                },
                child: ListTile(
                  onTap: () => _openChat(c),
                  contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  leading: Icon(Icons.auto_awesome, size: 18, color: chats.streaming == c ? C.accent : C.dim2),
                  title: Text(
                    c.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15),
                  ),
                  subtitle: switch ((c.lastAnswer ?? '').replaceAll('\n', ' ')) {
                    '' => null,
                    final answer => Text(
                      answer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: C.dim),
                    ),
                  },
                  trailing: Text(stamp(c.updatedAt), style: const TextStyle(fontSize: 12, color: C.dim2)),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _openAccount() => showAppSheet<void>(
    context,
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
            const SizedBox(height: 8),
            ListTile(
              key: const ValueKey('tabs'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Tabs', style: TextStyle(fontWeight: FontWeight.w600)),
              trailing: const Icon(Icons.chevron_right, color: C.dim),
              onTap: () {
                Navigator.of(sheet).pop();
                unawaited(_openTabs());
              },
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

  /// Which tabs the bar shows and in what order: drag a row by its handle,
  /// switch a tab off or on. The bar follows at once; the last tab showing
  /// can't be switched off.
  Future<void> _openTabs() => showAppSheet<void>(
    context,
    builder: (_) => ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final tabs = widget.session.tabs;
        final last = tabs.visible.length == 1;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 2),
                child: Text('Tabs', style: sheetTitleStyle),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Text(
                  'Drag to reorder. With one tab left, the bar goes away.',
                  style: TextStyle(fontSize: 13, color: C.dim),
                ),
              ),
              ReorderableListView(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.only(bottom: 12),
                // [to] here already leaves the moved row out; moved() counts it.
                onReorderItem: (from, to) =>
                    unawaited(widget.session.setTabs(tabs.moved(from, to > from ? to + 1 : to))),
                // The lifted row on the sheet's own surface, not Material's default.
                proxyDecorator: (child, _, _) => Material(
                  color: isIos ? S.fill : M.container,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(12),
                  child: child,
                ),
                children: [
                  for (final (i, tab) in tabs.order.indexed)
                    // iOS's own switch on iPhone; the last one showing stays
                    // on but can't be switched off.
                    SwitchListTile.adaptive(
                      key: ValueKey('tab-${tab.name}'),
                      contentPadding: const EdgeInsets.only(left: 8, right: 20),
                      value: tabs.shows(tab),
                      activeTrackColor: C.accent,
                      onChanged: last && tabs.shows(tab)
                          ? null
                          : (_) => unawaited(widget.session.setTabs(tabs.toggled(tab))),
                      secondary: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ReorderableDragStartListener(
                            index: i,
                            child: const Padding(
                              padding: EdgeInsets.all(8),
                              child: Icon(Icons.drag_handle, color: C.dim2),
                            ),
                          ),
                          Icon(tab.icon, color: C.dim),
                        ],
                      ),
                      title: Text(tab.label, style: const TextStyle(fontSize: 15)),
                    ),
                ],
              ),
            ],
          ),
        );
      },
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
      // Scrolls rather than overflows when a long description meets the
      // keyboard on a small phone.
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                builder: (context, _) {
                  final at = parseReminder(_title.text, DateTime.now()).at;
                  return Reveal(
                    visible: at != null,
                    child: at == null
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Align(alignment: Alignment.centerLeft, child: ReminderChip(at)),
                          ),
                  );
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
            Reveal(
              visible: _kind == Kind.idea && widget.store.projects.isNotEmpty,
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SizedBox(
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
              ),
            ),
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
      actions: [
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline),
          onPressed: () {
            widget.store.delete(idea);
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                undoSnackBar(idea.isTodo ? 'Todo deleted' : 'Idea deleted', () => widget.store.restore(idea)),
              );
          },
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) => ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
  final picked = await showAppSheet<({DateTime? at})>(context, builder: (_) => _ReminderSheet(current: todo.remindAt));
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
          const Text('Remind me', style: sheetTitleStyle),
          const SizedBox(height: 8),
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

  /// The bar at the bottom, which toasts keep clear of.
  final GlobalKey _composer = GlobalKey();

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
        ..showSnackBar(
          SnackBar(
            content: const Text('There is no image on the clipboard.'),
            behavior: SnackBarBehavior.floating,
            margin: toastMargin(_composer),
          ),
        );
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
          title: Text(c?.title ?? 'New chat', maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (c != null)
              IconButton(
                tooltip: 'Copy last answer',
                onPressed: () => copyAnswer(context, c.lastAnswer),
                icon: const Icon(Icons.content_copy),
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
                key: _composer,
                decoration: const BoxDecoration(
                  color: C.bar,
                  border: Border(top: BorderSide(color: C.line)),
                ),
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                child: const SafeArea(top: false, child: NoAiNotice()),
              )
            else
              Container(
                key: _composer,
                decoration: const BoxDecoration(
                  color: C.bar,
                  border: Border(top: BorderSide(color: C.line)),
                ),
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: SafeArea(
                  top: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Its own gap above it, only while it holds images.
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: AttachmentStrip(attachments: _attachments, top: 6),
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
        title: Text(note == null ? 'New note' : stamp(note.updatedAt)),
        actions: [
          if (note != null) ...[
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.content_copy),
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
