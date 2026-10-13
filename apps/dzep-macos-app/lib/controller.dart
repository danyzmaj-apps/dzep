import 'dart:async';

import 'package:dzep_core/chat.dart';
import 'package:dzep_core/idea.dart';
import 'package:dzep_core/kitty.dart';
import 'package:dzep_core/native.dart';
import 'package:dzep_core/session.dart';
import 'package:dzep_core/store.dart';
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

  /// What the popup opens on: the mode it was last used in.
  PopupMode get popupMode => PopupMode.values.asNameMap()[_prefs.getString('popup_mode')] ?? PopupMode.idea;

  void setPopupMode(PopupMode mode) => unawaited(_prefs.setString('popup_mode', mode.name));

  HotKey get hotKey => _hotKey;
  late HotKey _hotKey = _loadHotKey();
  bool hotKeyRegistered = false;

  static const _terminalKey = 'terminal_bridge';

  /// The iPhone may see and type into kitty and omp (lib/terminal_bridge.dart).
  /// Off until turned on in Settings: whoever holds the account can then type
  /// here.
  bool get terminalOn => _prefs.getBool(_terminalKey) ?? false;
  TerminalBridge? _bridge;
  final kitty = Kitty();

  /// The omp sessions reporting to the local API (integrations/omp/live.ts).
  late final live = LiveHub()..events.listen((e) => unawaited(_onLive(e)));

  Future<void> setTerminal({required bool on}) async {
    await _prefs.setBool(_terminalKey, on);
    notifyListeners();
    await _startBridge();
  }

  /// One bridge for the signed-in user while [terminalOn].
  Future<void> _startBridge() async {
    final user = this.user;
    final want = terminalOn && user != null;
    if (want == (_bridge != null)) return;
    final old = _bridge;
    _bridge = null;
    await old?.stop();
    if (want) await (_bridge = TerminalBridge(client, user.id, kitty, live)).start();
  }

  /// An omp run ended, or omp waits for an answer: the iPhone hears about it,
  /// unless it's showing that session right now.
  Future<void> _onLive(LiveEvent e) async {
    final s = e.session;
    if (_bridge?.watching(s.key) ?? false) return;
    final (title, body) = switch (e) {
      LiveFinished(:final summary) => ('omp finished · ${s.project}', summary),
      LiveAsked(:final ask) => ('omp needs you · ${s.project}', ask.text),
    };
    await notifyPhone(title, body, session: s.key);
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
    await _startBridge();
    _shownTodoCount = 0;
    await Native.setTodoCount(0);
    await Native.setSharedTodos(null);
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

  // ---------------------------------------------------------------- window

  void _onNative(String event, Map<Object?, Object?> args) {
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

  /// Pushes [title] / [body] to the user's iPhones (functions/push) when
  /// nobody has touched this Mac for a minute: at the desk, the Mac's own
  /// screen says it already. [session]: the omp session a tap opens. False if
  /// it didn't go.
  Future<bool> notifyPhone(String title, String body, {String? session}) async {
    if (store == null || await Native.idleSeconds() < 60) return false;
    try {
      final res = await client.functions.invoke(
        'push',
        body: {'action': 'notify', 'title': title, 'body': body, 'session': ?session},
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
