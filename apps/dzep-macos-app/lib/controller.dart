import 'dart:async';
import 'dart:io';

import 'package:dzep_core/agent.dart';
import 'package:dzep_core/chat.dart';
import 'package:dzep_core/idea.dart';
import 'package:dzep_core/native.dart';
import 'package:dzep_core/session.dart';
import 'package:dzep_core/store.dart';
import 'package:dzep_core/terminals.dart';
import 'package:dzep_macos/live_hub.dart';
import 'package:dzep_macos/terminal_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The popup's modes, switched with ⌘1–⌘4.
enum PopupMode { idea, todo, note, ask }

/// The Mac app: [Session] plus its windows (the ⇧⌘Space popup panel, the
/// main window and the note window, each its own Flutter view) and the
/// hotkey.
class AppController extends Session {
  AppController(this._prefs, super.device);

  final SharedPreferences _prefs;

  /// The popup panel is on screen.
  bool get popupOpen => _popupOpen;
  bool _popupOpen = false;

  /// The main window is open (Džep is a regular app with a Dock icon then).
  bool get mainOpen => _mainOpen;
  bool _mainOpen = false;

  /// The note window is on screen: one note, floating apart from the app.
  bool get noteOpen => _noteOpen;
  bool _noteOpen = false;

  /// The note it shows; null for a new one until something is written.
  String? noteId;

  /// Bumped on every note window open, so it starts over on its note.
  int noteSession = 0;

  /// The note window has the keyboard. macOS says so; Flutter can't tell,
  /// all the windows sharing one FocusManager.
  bool noteKey = false;

  /// The main window gave way to the note window: it comes back when that
  /// closes.
  bool _mainAfterNote = false;

  /// Bumped on every popup open so it resets (focus, selection).
  int popupSession = 0;

  bool settingsOpen = false;

  /// Idea the main window should select next (from the popup's list).
  String? pendingSelect;

  /// The list the main window should show next (popup ⌘O: Ideas, Todos or
  /// Notes, the popup's mode).
  Kind? pendingSection;

  /// Conversation the main window's Chats should show next (popup ⌘O).
  Conversation? pendingChat;

  /// The main window should show Ask next (popup ⌘O in Ask, even with no
  /// chat to show yet).
  bool pendingChats = false;

  /// The next popup open goes straight to the chat (Continue in popup).
  bool askNext = false;

  /// The main window should open the sheet that connects an AI next (the
  /// popup's Ask, which has no room for it).
  bool pendingConnectAi = false;

  /// What the popup opens on: the mode it was last used in.
  PopupMode get popupMode => PopupMode.values.asNameMap()[_prefs.getString('popup_mode')] ?? PopupMode.idea;

  void setPopupMode(PopupMode mode) => unawaited(_prefs.setString('popup_mode', mode.name));

  HotKey get hotKey => _hotKey;
  late HotKey _hotKey = _loadHotKey();
  bool hotKeyRegistered = false;

  static const _terminalKey = 'terminal_bridge';

  /// The phone may see and type into the Mac's terminals and the coding
  /// sessions (lib/terminal_bridge.dart). Off until turned on in Settings:
  /// whoever holds the account can then type here.
  bool get terminalOn => _prefs.getBool(_terminalKey) ?? false;
  TerminalBridge? _bridge;

  /// Whose `terminal:<uid>` channel [_bridge] is on.
  String? _bridgeUser;

  /// [_startBridge] calls, one after the other.
  Future<void> _bridging = Future.value();

  /// The Mac's terminals (kitty's sockets in [kittyDir]).
  late final Terminals terminals = Terminals.standard(kittyDir: kittyDir(Platform.environment));

  /// Where kitty's sockets are: /tmp, or the directory `DZEP_KITTY_DIR`
  /// names, so a second Džep under test talks to a kitty of its own.
  @visibleForTesting
  static String kittyDir(Map<String, String> env) {
    final dir = env['DZEP_KITTY_DIR'];
    return dir != null && dir.isNotEmpty ? dir : '/tmp';
  }

  static const _terminalAppKey = 'terminal_app';

  /// The terminal app new sessions from the phone open in: an app's id
  /// (lib/terminal.dart), or `auto` (the one used last).
  String get terminalApp => _prefs.getString(_terminalAppKey) ?? 'auto';

  Future<void> setTerminalApp(String id) async {
    await _prefs.setString(_terminalAppKey, id);
    notifyListeners();
  }

  static const _agentKey = 'coding_agent';

  /// The coding agent a new session from the phone starts.
  Agent get codingAgent => Agent.parse(_prefs.getString(_agentKey));

  Future<void> setCodingAgent(Agent agent) async {
    await _prefs.setString(_agentKey, agent.name);
    notifyListeners();
  }

  /// The coding sessions reporting to the local API (integrations/).
  late final live = LiveHub(locate: (term, cwd) => terminals.locate(term, cwd: cwd))
    ..events.listen((e) => unawaited(_onLive(e)));

  Future<void> setTerminal({required bool on}) async {
    await _prefs.setBool(_terminalKey, on);
    notifyListeners();
    await _startBridge();
  }

  /// One bridge for the signed-in user while [terminalOn]: a new one when
  /// the user changes, none when they're gone however they went. Calls run
  /// one at a time, so two at once (the switch while a sign-in lands) don't
  /// both build one.
  Future<void> _startBridge() {
    final next = _bridging.then((_) => _syncBridge());
    _bridging = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _syncBridge() async {
    final want = terminalOn ? user?.id : null;
    if (want == _bridgeUser) return;
    final old = _bridge;
    _bridge = null;
    _bridgeUser = null;
    await old?.stop();
    if (want != null) {
      _bridgeUser = want;
      await (_bridge = TerminalBridge(client, want, terminals, live, () => codingAgent, () => terminalApp)).start();
    }
  }

  /// A run ended, or the agent waits for an answer: the phones hear about
  /// it, unless it's showing that session right now.
  Future<void> _onLive(LiveEvent e) async {
    final s = e.session;
    if (_bridge?.watching(s.key) ?? false) return;
    final (title, body, state) = switch (e) {
      LiveFinished(:final summary) => ('${s.agent.label} finished · ${s.project}', summary, 'done'),
      LiveAsked(:final ask) => ('${s.agent.label} needs you · ${s.project}', ask.text, 'needs'),
    };
    await notifyPhone(title, body, session: s.key, activity: state);
  }

  @override
  Future<void> start() async {
    Native.listen(_onNative);
    hotKeyRegistered = await Native.setHotKey(_hotKey);
    await super.start();
    // Not set up or signed out: there's nothing to do but that, so say so.
    if (user == null) await openMain();
  }

  @override
  Future<void> signOut() async {
    settingsOpen = false;
    _mainAfterNote = false;
    await closeNoteWindow();
    await super.signOut();
  }

  int _shownTodoCount = 0;

  @override
  Future<void> onSignedIn(IdeaStore store) async {
    void update() {
      if (this.store != store) return;
      final open = store.openTodos;
      // The desktop widget's snapshot; Swift reloads the widget only on a change.
      unawaited(
        Native.setSharedTodos([
          for (final t in open) {'id': t.id, 'title': t.title},
        ]),
      );
      if (open.length == _shownTodoCount) return;
      _shownTodoCount = open.length;
      unawaited(Native.setTodoCount(open.length));
    }

    store.addListener(update);
    update();
    // Ticks the widget queued while Džep wasn't running.
    await drainPending();
    await _startBridge();
  }

  /// However the user went (signed out here, the server refused a refresh,
  /// the account was deleted on another device): the desktop widget and the
  /// Dock badge stop showing their todos, and the terminal bridge stops.
  @override
  Future<void> onSignedOut() async {
    _shownTodoCount = 0;
    await Native.setTodoCount(0);
    await Native.setSharedTodos(null);
    try {
      await _startBridge();
    } on Object catch (e) {
      debugPrint('Džep: terminal bridge not stopped: $e');
    }
  }

  /// A setup link to another server waits for a yes: in the main window.
  @override
  void onLinkToConfirm() => unawaited(openMain());

  // ---------------------------------------------------------------- window

  /// Runs when Džep quits, before the app goes (a second at most): the
  /// local API takes itself out of cli.json (lib/main.dart).
  Future<void> Function()? onQuit;

  FutureOr<void> _onNative(String event, Map<Object?, Object?> args) {
    switch (event) {
      case 'hotKey' || 'togglePopup':
        unawaited(_popupOpen ? closePopup() : openPopup());
      case 'openMain':
        unawaited(openMain());
      case 'openSettings':
        settingsOpen = true;
        unawaited(openMain());
      case 'blur':
        // Clicking elsewhere dismisses the popup, like Spotlight; a file
        // dialog the popup opened doesn't.
        if (_popupOpen && !_holdPopup) unawaited(closePopup());
      case 'mainClosed':
        _mainOpen = false;
        notifyListeners();
      case 'closeNote':
        unawaited(closeNoteWindow());
      case 'noteKey':
        noteKey = args['key'] == true;
        notifyListeners();
      case 'openTodo':
        // A reminder notification clicked: that todo, selected.
        unawaited(openMain(select: args['id'] as String?));
      case 'pending':
        // Ticks from outside Dart (the desktop widget) wait in the App Group.
        unawaited(drainPending());
      case 'quitting':
        return onQuit?.call();
    }
  }

  bool _holdPopup = false;

  /// Runs [pick] (a file dialog) from the popup: it takes the focus, which
  /// would otherwise close the popup; the popup takes it back after.
  Future<void> pickFromPopup(Future<void> Function() pick) async {
    _holdPopup = true;
    try {
      await pick();
    } finally {
      _holdPopup = false;
      if (_popupOpen) await Native.showPopup();
    }
  }

  Future<void> openPopup() async {
    popupSession++;
    _popupOpen = true;
    notifyListeners();
    await Native.showPopup();
  }

  Future<void> closePopup() async {
    _popupOpen = false;
    notifyListeners();
    await Native.hidePopup();
  }

  /// Shows [c] in the popup's chat.
  Future<void> openAsk(Conversation c) async {
    chats?.resume(c);
    askNext = true;
    await openPopup();
  }

  /// Shows the main window; [select] an item, [conversation] a chat, or
  /// [section] that kind's list, or [chats] Ask.
  Future<void> openMain({String? select, Conversation? conversation, Kind? section, bool chats = false}) async {
    if (select != null) pendingSelect = select;
    if (conversation != null) pendingChat = conversation;
    if (chats) pendingChats = true;
    if (section != null) pendingSection = section;
    if (_popupOpen) await closePopup();
    // Back already: closing the note window leaves it be.
    _mainAfterNote = false;
    _mainOpen = true;
    notifyListeners();
    await Native.showMain();
  }

  /// The main window on Ask, with the sheet that connects an AI.
  Future<void> connectAi() {
    pendingConnectAi = true;
    return openMain(chats: true);
  }

  /// Shows note [id] (null: a new one) in the note window. From the main
  /// window ([fromMain]) the app hides until the note window closes; from
  /// the popup it stays as it was.
  Future<void> openNoteWindow({String? id, bool fromMain = false}) async {
    if (_popupOpen) await closePopup();
    noteId = id;
    noteSession++;
    _noteOpen = true;
    final hideMain = fromMain && _mainOpen;
    if (hideMain) {
      _mainOpen = false;
      _mainAfterNote = true;
    }
    notifyListeners();
    await Native.showNote(hideMain: hideMain);
  }

  /// Closes the note window; the main window comes back on that note if it
  /// gave way to it.
  Future<void> closeNoteWindow() async {
    if (!_noteOpen) return;
    _noteOpen = false;
    noteKey = false;
    final back = _mainAfterNote;
    _mainAfterNote = false;
    notifyListeners();
    await Native.hideNote();
    if (back) await openMain(select: noteId);
  }

  void setSettingsOpen({required bool open}) {
    settingsOpen = open;
    notifyListeners();
  }

  /// Pushes [title] / [body] to the user's phones (functions/push) when
  /// nobody has touched this Mac for a minute: at the desk, the Mac's own
  /// screen says it already. [session]: the coding session a tap opens,
  /// whose Live Activities move to [activity] (done, needs). False if it
  /// didn't go.
  Future<bool> notifyPhone(String title, String body, {String? session, String? activity}) async {
    if (store == null || await Native.idleSeconds() < 60) return false;
    try {
      final res = await client.functions.invoke(
        'push',
        body: {'action': 'notify', 'title': title, 'body': body, 'session': ?session, 'state': ?activity},
      );
      final data = res.data;
      return data is Map && (data['sent'] as int? ?? 0) > 0;
    } on Object catch (e) {
      debugPrint('Džep: notify failed: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------- hotkey

  HotKey _loadHotKey() {
    final saved = _prefs.getString('hotkey');
    if (saved == null) return HotKey.fallback;
    try {
      return HotKey.decode(saved);
    } on Object {
      return HotKey.fallback;
    }
  }

  /// False when macOS refused it (another app owns the combo); the old one
  /// stays then.
  Future<bool> setHotKey(HotKey key) async {
    final ok = await Native.setHotKey(key);
    if (ok) {
      _hotKey = key;
      hotKeyRegistered = true;
      await _prefs.setString('hotkey', key.encode());
    } else {
      hotKeyRegistered = await Native.setHotKey(_hotKey);
    }
    notifyListeners();
    return ok;
  }
}
