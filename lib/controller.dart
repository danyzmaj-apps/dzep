import 'dart:async';

import 'package:dzep/chat.dart';
import 'package:dzep/kitty.dart';
import 'package:dzep/native.dart';
import 'package:dzep/session.dart';
import 'package:dzep/store.dart';
import 'package:dzep/terminal.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The popup's modes, switched with ⌘1–⌘4.
enum PopupMode { idea, todo, note, ask }

/// The Mac app: [Session] plus its two windows (the ⇧⌘Space popup panel and
/// the main window, each its own Flutter view) and the hotkey.
class AppController extends Session {
  AppController(this._prefs, super.device);

  final SharedPreferences _prefs;

  /// The popup panel is on screen.
  bool get popupOpen => _popupOpen;
  bool _popupOpen = false;

  /// The main window is open (Džep is a regular app with a Dock icon then).
  bool get mainOpen => _mainOpen;
  bool _mainOpen = false;

  /// Bumped on every popup open so it resets (focus, selection).
  int popupSession = 0;

  bool settingsOpen = false;

  /// Idea the main window should select next (from the popup's list).
  String? pendingSelect;

  /// The main window should show the notes next (popup ⌘O in the note mode).
  bool pendingNotes = false;

  /// Conversation the main window's Chats should show next (popup ⌘O).
  Conversation? pendingChat;

  /// The next popup open goes straight to the chat (Continue in popup).
  bool askNext = false;

  /// What the popup opens on: the mode it was last used in.
  PopupMode get popupMode => PopupMode.values.asNameMap()[_prefs.getString('popup_mode')] ?? PopupMode.idea;

  void setPopupMode(PopupMode mode) => unawaited(_prefs.setString('popup_mode', mode.name));

  HotKey get hotKey => _hotKey;
  late HotKey _hotKey = _loadHotKey();
  bool hotKeyRegistered = false;

  static const _terminalKey = 'terminal_bridge';

  /// The iPhone may see and type into kitty (lib/terminal.dart). Off until
  /// turned on in Settings: whoever holds the account can then type here.
  bool get terminalOn => _prefs.getBool(_terminalKey) ?? false;
  TerminalBridge? _bridge;
  final kitty = Kitty();

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
    if (want) await (_bridge = TerminalBridge(client, user.id, kitty)).start();
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
  /// [notes] the notes list.
  Future<void> openMain({String? select, Conversation? conversation, bool notes = false}) async {
    if (select != null) pendingSelect = select;
    if (conversation != null) pendingChat = conversation;
    if (notes) pendingNotes = true;
    if (_popupOpen) await closePopup();
    _mainOpen = true;
    notifyListeners();
    await Native.showMain();
  }

  void setSettingsOpen({required bool open}) {
    settingsOpen = open;
    notifyListeners();
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
